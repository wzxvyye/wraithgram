#!/usr/bin/env python3
"""Rebrand an existing WraithGram .ipa into Wraithgram.ipa on Windows.

This does not compile anything: it replaces the display name and the loose
AppIcon*.png files inside an already-built IPA. Use it when you have a
sideload-ready WraithGram IPA (not an encrypted App Store download).

    python -m pip install pillow
    python tools/rebrand_ipa.py "C:\\path\\Wraithgram.ipa"

Sideloadly / AltStore re-signs the result with your own Apple ID.
"""

from __future__ import annotations

import argparse
import plistlib
import sys
import zipfile
from pathlib import Path

APP_NAME = "Wraithgram"
DEFAULT_ICON = Path(__file__).with_name("wraithgram-icon.png")


def load_pillow():
    try:
        from PIL import Image
    except ImportError:
        sys.exit(
            "Pillow is required to resize the icon.\n"
            "Run:  python -m pip install pillow"
        )
    return Image


def find_app_dir(names: list[str]) -> str:
    apps = sorted(
        {
            "/".join(name.split("/")[:2])
            for name in names
            if name.startswith("Payload/") and name.count("/") >= 2 and name.split("/")[1].endswith(".app")
        }
    )
    if not apps:
        sys.exit("ERROR: no Payload/*.app found — this does not look like an IPA.")
    if len(apps) > 1:
        print(f"NOTE: several apps in Payload, using {apps[0]}")
    return apps[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Rebrand a WraithGram IPA into Wraithgram.ipa")
    parser.add_argument("ipa", type=Path, help="input .ipa")
    parser.add_argument("-o", "--output", type=Path, help="output .ipa (default: Wraithgram.ipa next to the input)")
    parser.add_argument("-i", "--icon", type=Path, default=DEFAULT_ICON, help=f"1024x1024 PNG (default: {DEFAULT_ICON})")
    args = parser.parse_args()

    if not args.ipa.is_file():
        sys.exit(f"ERROR: {args.ipa} not found")
    if not args.icon.is_file():
        sys.exit(f"ERROR: icon {args.icon} not found (pass --icon)")

    Image = load_pillow()
    output = args.output or args.ipa.with_name(f"{APP_NAME}.ipa")

    with zipfile.ZipFile(args.ipa) as zin:
        names = zin.namelist()
        app_dir = find_app_dir(names)
        info_path = f"{app_dir}/Info.plist"

        if info_path not in names:
            sys.exit(f"ERROR: {info_path} not found")

        info = plistlib.loads(zin.read(info_path))
        old_name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or "?"
        info["CFBundleDisplayName"] = APP_NAME
        info["CFBundleName"] = APP_NAME
        new_info = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)

        icon_names = [
            name
            for name in names
            if name.startswith(app_dir + "/")
            and name.count("/") == app_dir.count("/") + 1
            and name.rsplit("/", 1)[1].startswith("AppIcon")
            and name.lower().endswith(".png")
        ]

        source_icon = Image.open(args.icon).convert("RGB")

        print(f"input     : {args.ipa}")
        print(f"app       : {app_dir}")
        print(f"name      : {old_name!r} -> {APP_NAME!r}")
        print(f"icon      : {args.icon}")
        print(f"app icons : {len(icon_names)}")

        if not icon_names:
            print(
                "WARNING: no loose AppIcon*.png files. The icon is probably only inside "
                "Assets.car and cannot be replaced by this script.",
                file=sys.stderr,
            )

        replaced = 0
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if item.filename == info_path:
                    data = new_info
                elif item.filename in icon_names:
                    with Image.open(zin.open(item.filename)) as old_icon:
                        size = old_icon.size
                    resized = source_icon.resize(size, Image.LANCZOS)
                    from io import BytesIO

                    buf = BytesIO()
                    resized.save(buf, format="PNG", optimize=True)
                    data = buf.getvalue()
                    replaced += 1
                zout.writestr(item, data)

    print(f"icons     : replaced {replaced}")
    print(f"OK        : {output}")
    print("Next      : sideload it with Sideloadly or AltStore (they re-sign with your Apple ID).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
