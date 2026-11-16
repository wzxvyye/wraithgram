#!/usr/bin/env python3
"""Browser bridge for driving an iOS Simulator through `idb`.

Serves a live view of the simulator screen and forwards taps / swipes /
keystrokes into it. Standard library only.

The picture comes from `idb video-stream` (a continuous MJPEG stream of the
simulator framebuffer) rather than repeated `simctl` screenshots, which is
far faster and smoother. Only the newest frame is kept, and the browser pulls
one frame at a time (`/frame`), so a slow client never builds up a backlog and
the picture never "freezes behind" reality. If the video stream is
unavailable, it falls back to `xcrun simctl io` screenshots downscaled with
`sips`. Requests are served on a keep-alive HTTP/1.1 connection so taps are
cheap.

Environment:
  SIM_UDID         target simulator UDID (required)
  BRIDGE_TOKEN     shared secret required on every request (required)
  BRIDGE_PORT      listen port (default 8080)
  STREAM_FORMAT    idb video-stream format (default mjpeg)
  STREAM_FPS       idb video-stream frame rate (default 24)
  STREAM_SCALE     idb video-stream scale factor 0..1 (default 0.25)
  STREAM_QUALITY   idb video-stream compression quality 0..1 (default 0.5)
  FRAME_MAX_AGE    seconds a captured frame stays usable (default 1.0)

Endpoints (all require ?k=<token>):
  GET  /                      the page
  GET  /ws                    live frame push over WebSocket (smooth)
  GET  /stream                live MJPEG stream (fallback, may be buffered)
  GET  /frame                 newest screen frame as a single JPEG
  GET  /diag                  screen size + accessibility labels
  GET  /health                liveness + screen size + video state
  POST /tap?nx=&ny=           tap at normalised (0..1) coordinates
  POST /swipe?nx1=&ny1=&nx2=&ny2=&ms=
  POST /text                  body is the text to type
  POST /key?code=             HID usage code (40 = Enter, 42 = Backspace, ...)
  POST /button?name=HOME|LOCK|SIRI
"""

import base64
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UDID = os.environ.get("SIM_UDID", "").strip()
TOKEN = os.environ.get("BRIDGE_TOKEN", "").strip()
PORT = int(os.environ.get("BRIDGE_PORT", "8080"))
FRAME_DIR = tempfile.mkdtemp(prefix="simframe")
FRAME_MAX = int(os.environ.get("FRAME_MAX", "620"))
FRAME_QUALITY = os.environ.get("FRAME_QUALITY", "55")
FRAME_MAX_AGE = float(os.environ.get("FRAME_MAX_AGE", "1.0"))
STREAM_FORMAT = os.environ.get("STREAM_FORMAT", "mjpeg")
STREAM_FPS = os.environ.get("STREAM_FPS", "24")
STREAM_SCALE = os.environ.get("STREAM_SCALE", "0.25")
STREAM_QUALITY = os.environ.get("STREAM_QUALITY", "0.5")

_lock = threading.Lock()
_points = {"w": 0.0, "h": 0.0}

PAGE = """<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Wraithgram — живой симулятор</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; background:#0d1117; color:#e6edf3;
               font:14px/1.4 -apple-system,Segoe UI,Roboto,sans-serif; overflow:hidden; }
  #wrap { height:100%; display:flex; flex-direction:column; }
  header { padding:8px 14px; font-weight:600; display:flex; justify-content:space-between;
           align-items:center; gap:12px; flex:0 0 auto; }
  #status { opacity:.6; font-size:12px; font-weight:400; }
  #stage { flex:1 1 auto; display:flex; align-items:center; justify-content:center;
           padding:0 10px 6px; min-height:0; }
  #screen { max-height:100%; max-width:100%; border-radius:16px; background:#000;
            box-shadow:0 8px 40px #000c; cursor:crosshair; touch-action:none;
            user-select:none; -webkit-user-select:none; -webkit-touch-callout:none; }
  #foot { flex:0 0 auto; padding:8px 12px 12px; display:flex; gap:8px; justify-content:center; }
  #txt { flex:1 1 auto; max-width:460px; background:#21262d; color:#e6edf3;
         border:1px solid #30363d; border-radius:10px; padding:10px 12px; font-size:15px; }
  #txt:focus { outline:none; border-color:#58a6ff; }
  button { background:#21262d; color:#e6edf3; border:1px solid #30363d; border-radius:10px;
           padding:10px 16px; font-size:15px; cursor:pointer; }
  button:active { background:#30363d; }
  #hint { text-align:center; opacity:.5; font-size:12px; padding:0 12px 8px; }
</style></head>
<body>
<div id="wrap">
  <header><span>Wraithgram — живой симулятор iPhone</span><span id="status">подключение…</span></header>
  <div id="stage"><img id="screen" alt="экран симулятора" draggable="false"></div>
  <div id="hint">Клик по экрану — тап. Проведи мышью/пальцем — свайп. Печатай с клавиатуры — текст уходит в телефон.</div>
  <div id="foot">
    <input id="txt" placeholder="текст с телефона — Enter, чтобы отправить" autocomplete="off"
           autocapitalize="off" autocorrect="off" spellcheck="false">
    <button id="send">Ввод</button>
  </div>
</div>
<script>
const K = new URLSearchParams(location.search).get('k') || '';
const img = document.getElementById('screen');
const statusEl = document.getElementById('status');
const txt = document.getElementById('txt');
const q = (p) => p + (p.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(K);
const post = (p, opts) => fetch(q(p), opts || { method:'POST' });

function setStatus(t){ statusEl.textContent = t; }

// ---- live view ----
// Preferred: a WebSocket (`/ws`) that pushes each frame as it is captured,
// which looks like smooth video and is not held back by proxy buffering. If
// it does not start or drops, fall back to pulling single frames (`/frame`),
// which can never lag behind.
let mode = 'ws';
let gotFrame = false;
let watchdog = null;
let ws = null;

function armWatchdog(){
  clearTimeout(watchdog);
  watchdog = setTimeout(() => { setStatus('нет ответа — повтор…'); tick(); }, 6000);
}
function tick(){
  if (mode !== 'poll') return;
  armWatchdog();
  img.src = q('/frame') + '&t=' + Date.now();
}
function usePoll(){
  if (mode === 'poll') return;
  mode = 'poll';
  try { if (ws) { ws.onclose = null; ws.close(); } } catch (e) {}
  setStatus('покадровый режим');
  tick();
}
function useWs(){
  let url;
  try {
    url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host +
          '/ws?k=' + encodeURIComponent(K);
    ws = new WebSocket(url);
  } catch (e) { usePoll(); return; }
  ws.binaryType = 'blob';
  let prev = null;
  ws.onmessage = (ev) => {
    gotFrame = true;
    const nu = URL.createObjectURL(ev.data);
    img.src = nu;
    if (prev) setTimeout(() => URL.revokeObjectURL(prev), 3000);
    prev = nu;
    setStatus('живое видео ' + new Date().toLocaleTimeString());
  };
  ws.onopen = () => setStatus('живое видео — подключено');
  ws.onerror = () => usePoll();
  ws.onclose = () => usePoll();
}
img.addEventListener('load', () => {
  if (mode === 'ws') { gotFrame = true; return; }
  clearTimeout(watchdog);
  setStatus('в эфире ' + new Date().toLocaleTimeString());
  setTimeout(tick, 0);
});
img.addEventListener('error', () => {
  if (mode === 'ws') return;
  clearTimeout(watchdog);
  setStatus('нет кадра — повтор…');
  setTimeout(tick, 700);
});
useWs();
setTimeout(() => { if (mode === 'ws' && !gotFrame) usePoll(); }, 9000);

// ---- tap / swipe directly on the screen ----
let start = null, moved = false, t0 = 0;
function norm(ev){
  const r = img.getBoundingClientRect();
  return { nx: Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width)),
           ny: Math.min(1, Math.max(0, (ev.clientY - r.top) / r.height)) };
}
img.addEventListener('pointerdown', (ev) => {
  ev.preventDefault();
  try { img.setPointerCapture(ev.pointerId); } catch (e) {}
  start = norm(ev); moved = false; t0 = Date.now();
});
img.addEventListener('pointermove', (ev) => {
  if (!start) return;
  const p = norm(ev);
  const dx = (p.nx - start.nx) * img.clientWidth;
  const dy = (p.ny - start.ny) * img.clientHeight;
  if (Math.hypot(dx, dy) > 10) moved = true;
});
img.addEventListener('pointerup', async (ev) => {
  if (!start) return;
  const end = norm(ev); const dur = Date.now() - t0; const s = start; start = null;
  if (!moved) {
    setStatus('тап…');
    await post('/tap?nx=' + s.nx.toFixed(5) + '&ny=' + s.ny.toFixed(5));
    setStatus('в эфире');
  } else {
    const ms = Math.max(120, Math.min(1500, dur));
    setStatus('свайп…');
    await post('/swipe?nx1=' + s.nx.toFixed(5) + '&ny1=' + s.ny.toFixed(5) +
               '&nx2=' + end.nx.toFixed(5) + '&ny2=' + end.ny.toFixed(5) + '&ms=' + ms);
    setStatus('в эфире');
  }
});
img.addEventListener('pointercancel', () => { start = null; });

// ---- physical keyboard forwarding ----
const HID = { Enter:40, Backspace:42, Tab:43, Escape:41, Delete:76,
              ArrowLeft:80, ArrowRight:79, ArrowUp:82, ArrowDown:81 };
window.addEventListener('keydown', async (ev) => {
  if (ev.target === txt) return;               // the text field handles its own keys
  if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
  const code = HID[ev.key];
  if (code) { ev.preventDefault(); await post('/key?code=' + code); return; }
  if (ev.key.length === 1) { ev.preventDefault(); await post('/text', { method:'POST', body: ev.key }); }
});

// ---- text field (for phones without a hardware keyboard) ----
async function sendText(){
  const v = txt.value; if (!v) return;
  await post('/text', { method:'POST', body: v });
  txt.value = '';
}
document.getElementById('send').addEventListener('click', sendText);
txt.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); sendText(); } });
</script>
</body></html>
"""


def run(cmd, timeout=25):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        class _R:  # minimal stand-in so callers can read .returncode/.stdout/.stderr
            returncode = 124
            stdout = ""
            stderr = "timeout"
        return _R()


def idb(*args, timeout=25):
    return run(["idb", *args, "--udid", UDID], timeout=timeout)


def png_size(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(24)
    except OSError:
        return (0, 0)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return (0, 0)
    return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))


def is_jpeg(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"\xff\xd8"
    except OSError:
        return False


def screenshot_png(path):
    return run(["xcrun", "simctl", "io", UDID, "screenshot", path], timeout=25).returncode == 0 \
        and os.path.exists(path)


def screenshot_jpeg(path):
    """Newer simctl can emit JPEG directly, which skips a whole PNG encode."""
    res = run(["xcrun", "simctl", "io", UDID, "screenshot", "--type=jpeg", path], timeout=25)
    return res.returncode == 0 and is_jpeg(path)


def compute_points_from_screenshot():
    """Fast: the logical size is the pixel size divided by the display scale.

    Every current iPhone is scale 3, so a screenshot is a reliable source. The
    accessibility tree is consulted in the background only to log a warning.
    """
    probe = os.path.join(FRAME_DIR, "probe.png")
    for _ in range(15):
        if screenshot_png(probe):
            pw, ph = png_size(probe)
            if pw:
                scale = 3 if pw % 3 == 0 else 2
                return (pw / scale, ph / scale)
        time.sleep(2)
    return (0.0, 0.0)


def refine_points_from_ax():
    """Background: cross-check the size against the accessibility tree."""
    try:
        out = idb("ui", "describe-all").stdout
    except Exception as exc:  # noqa: BLE001
        print("describe-all failed:", exc, flush=True)
        return
    width = height = 0.0
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        frame = entry.get("frame") or {}
        try:
            x = float(frame.get("x", 0)); y = float(frame.get("y", 0))
            w = float(frame.get("width", 0)); h = float(frame.get("height", 0))
        except Exception:
            continue
        width = max(width, x + w)
        height = max(height, y + h)
    print(f"ax frame max: {width}x{height}", flush=True)
    with _lock:
        if width > 200 and height > 200:
            if abs(width - _points["w"]) <= 0.1 * _points["w"]:
                print("ax size agrees with screenshot", flush=True)
            else:
                print("WARNING: ax size disagrees with screenshot; keeping screenshot value", flush=True)


def current_points():
    with _lock:
        if _points["w"] < 100 or _points["h"] < 100:
            w, h = compute_points_from_screenshot()
            _points["w"], _points["h"] = w, h
        return dict(_points)


def make_frame_bytes():
    """Capture the simulator screen and return it as JPEG bytes."""
    raw = os.path.join(FRAME_DIR, "raw.jpg")
    if screenshot_jpeg(raw):
        src = raw
    else:
        png = os.path.join(FRAME_DIR, "frame.png")
        if not screenshot_png(png):
            return None
        src = png
    out = os.path.join(FRAME_DIR, "out.jpg")
    try:
        if os.path.exists(out):
            os.remove(out)
    except OSError:
        pass
    run(["sips", "-Z", str(FRAME_MAX), "-s", "format", "jpeg",
         "-s", "formatOptions", FRAME_QUALITY, src, "--out", out], timeout=25)
    path = out if os.path.exists(out) else src
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


class ScreenStream(threading.Thread):
    """Continuously reads `idb video-stream` and keeps only the newest frame.

    `idb` emits a JPEG-per-frame MJPEG stream of the simulator framebuffer,
    which is much faster than spawning `simctl` screenshots. Frames are split
    on their JPEG markers (SOI `FF D8` / EOI `FF D9`). If the process exits or
    the stream is unreadable the thread simply restarts it, and callers fall
    back to screenshots while no fresh frame is available.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.latest = None
        self.stamp = 0.0
        self.ok = False
        self._lock = threading.Lock()

    def _publish(self, frame):
        with self._lock:
            self.latest = frame
            self.stamp = time.time()
            self.ok = True

    def get(self, max_age=FRAME_MAX_AGE):
        with self._lock:
            if self.latest is not None and (time.time() - self.stamp) <= max_age:
                return self.latest
        return None

    def snapshot(self):
        with self._lock:
            return self.latest, self.stamp

    def run(self):
        while True:
            try:
                self._read_once()
            except Exception as exc:  # noqa: BLE001
                print("video stream error:", exc, flush=True)
            with self._lock:
                self.ok = False
            time.sleep(1.0)

    def _read_once(self):
        cmd = ["idb", "video-stream", "--udid", UDID,
               "--format", STREAM_FORMAT, "--fps", STREAM_FPS,
               "--scale-factor", STREAM_SCALE, "--compression-quality", STREAM_QUALITY]
        print("video stream:", " ".join(cmd), flush=True)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        buf = b""
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                buf += chunk
                buf = self._drain(buf)
                if len(buf) > 8_000_000:
                    buf = buf[-4_000_000:]
        finally:
            try:
                proc.kill()
            except Exception:  # noqa: BLE001
                pass
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                pass

    def _drain(self, buf):
        while True:
            start = buf.find(b"\xff\xd8")
            if start < 0:
                return buf[-1:]
            end = buf.find(b"\xff\xd9", start + 2)
            if end < 0:
                return buf[start:]
            frame = buf[start:end + 2]
            buf = buf[end + 2:]
            if len(frame) > 400:
                self._publish(frame)


stream = ScreenStream()


class Handler(BaseHTTPRequestHandler):
    server_version = "SimBridge/3.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the runner log quiet
        pass

    def _params(self):
        return urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

    def _authed(self):
        if not TOKEN:
            return True
        return self._params().get("k", [""])[0] == TOKEN

    def _send(self, code, ctype, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, code, payload):
        self._send(code, "application/json", json.dumps(payload))

    def _ws(self):
        """Push each new frame over a WebSocket (RFC 6455).

        Unlike a plain HTTP body, WebSocket frames are not held back by proxy
        buffering, so the picture arrives as it is captured. Only the newest
        frame is ever sent.
        """
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            return self._send(400, "text/plain", "expected websocket handshake")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        self.close_connection = True
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        last = 0.0
        try:
            while True:
                data, stamp = stream.snapshot()
                if data is None or stamp == last:
                    time.sleep(0.01)
                    continue
                last = stamp
                n = len(data)
                if n < 126:
                    hdr = bytes((0x82, n))
                elif n < 65536:
                    hdr = bytes((0x82, 126)) + n.to_bytes(2, "big")
                else:
                    hdr = bytes((0x82, 127)) + n.to_bytes(8, "big")
                self.wfile.write(hdr)
                self.wfile.write(data)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _stream(self):
        """Push the newest frame as fast as the client can take it.

        Only the latest frame is ever sent, so a slow client skips frames
        instead of falling further and further behind, and the picture stays
        close to real time.
        """
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Connection", "close")
        self.end_headers()
        last = 0.0
        try:
            while True:
                data, stamp = stream.snapshot()
                if data is None:
                    time.sleep(0.05)
                    continue
                if stamp == last:
                    time.sleep(0.01)
                    continue
                last = stamp
                header = ("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(data)).encode()
                self.wfile.write(header)
                self.wfile.write(data)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._authed():
            return self._send(403, "text/plain; charset=utf-8", "forbidden")
        if path in ("/", "/index.html"):
            return self._send(200, "text/html; charset=utf-8", PAGE)
        if path == "/stream":
            return self._stream()
        if path == "/ws":
            return self._ws()
        if path == "/frame":
            data = stream.get()
            if not data:
                data = make_frame_bytes()
            if not data:
                return self._send(503, "text/plain", "screenshot failed")
            return self._send(200, "image/jpeg", data)
        if path == "/diag":
            pts = current_points()
            labels = []
            try:
                for line in idb("ui", "describe-all").stdout.splitlines():
                    line = line.strip()
                    if line.startswith("{"):
                        try:
                            labels.append(json.loads(line).get("AXLabel"))
                        except Exception:
                            pass
            except Exception:
                pass
            return self._json(200, {"udid": UDID, "points": pts, "labels": labels[:80]})
        if path == "/health":
            return self._json(200, {"ok": True, "points": current_points(), "video": stream.ok})
        return self._send(404, "text/plain", "not found")

    def do_POST(self):
        if not self._authed():
            return self._send(403, "text/plain; charset=utf-8", "forbidden")
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""

        def num(key, default=0.0):
            try:
                return float(params.get(key, [default])[0])
            except (TypeError, ValueError):
                return default

        def with_retry(fn):
            res = fn()
            if res.returncode != 0:
                res = fn()
            return res

        try:
            if path == "/tap":
                pts = current_points()
                x = int(num("nx") * pts["w"])
                y = int(num("ny") * pts["h"])
                res = with_retry(lambda: idb("ui", "tap", str(x), str(y)))
                return self._json(200, {"tap": [x, y], "rc": res.returncode, "err": res.stderr.strip()[:200]})
            if path == "/swipe":
                pts = current_points()
                x1 = int(num("nx1") * pts["w"]); y1 = int(num("ny1") * pts["h"])
                x2 = int(num("nx2") * pts["w"]); y2 = int(num("ny2") * pts["h"])
                ms = int(num("ms", 300))
                res = with_retry(lambda: idb("ui", "swipe", str(x1), str(y1), str(x2), str(y2), "--duration", str(ms)))
                return self._json(200, {"swipe": [x1, y1, x2, y2], "rc": res.returncode, "err": res.stderr.strip()[:200]})
            if path == "/text":
                res = with_retry(lambda: idb("ui", "text", body))
                return self._json(200, {"text": body[:60], "rc": res.returncode, "err": res.stderr.strip()[:200]})
            if path == "/key":
                code = str(int(num("code")))
                res = with_retry(lambda: idb("ui", "key", code))
                return self._json(200, {"key": code, "rc": res.returncode, "err": res.stderr.strip()[:200]})
            if path == "/button":
                name = (params.get("name", ["HOME"])[0] or "HOME").upper()
                res = with_retry(lambda: idb("ui", "button", name))
                return self._json(200, {"button": name, "rc": res.returncode, "err": res.stderr.strip()[:200]})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        return self._send(404, "text/plain", "not found")


def main():
    if not UDID:
        print("SIM_UDID is required", flush=True)
        return 2
    if not TOKEN:
        print("BRIDGE_TOKEN is required", flush=True)
        return 2

    w, h = compute_points_from_screenshot()
    with _lock:
        _points["w"], _points["h"] = w, h
    print(f"screen points: {w}x{h}", flush=True)

    threading.Thread(target=refine_points_from_ax, daemon=True).start()
    stream.start()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"bridge listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
