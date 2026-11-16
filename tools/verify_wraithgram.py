#!/usr/bin/env python3
"""Checks the Wraithgram branding: app name, app icon and string tables.

Runs on Windows, macOS and Linux; it does not need Xcode or Bazel.

    python3 tools/verify_wraithgram.py

Exit code 0 means the branding files are consistent. The script also runs
Wraithgram/Strings/check.py, so a stale generated string table fails here too.

The actual iOS build still needs macOS with Xcode (see WRAITHGRAM.ru.md).
"""

import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(
    ROOT, "Telegram", "Telegram-iOS", "WraithgramAppIcon.xcassets", "AppIconLLC.appiconset"
)
ICON = os.path.join(ICON_DIR, "Wraithgram.png")
ICON_CONTENTS = os.path.join(ICON_DIR, "Contents.json")
BUILD = os.path.join(ROOT, "Telegram", "BUILD")
STRINGS_DIR = os.path.join(ROOT, "Wraithgram", "Strings")
GENERATED_DIR = os.path.join(ROOT, "Wraithgram", "WGCore", "Sources", "Strings", "Generated")
CHECK = os.path.join(STRINGS_DIR, "check.py")

errors = []
warnings = []


def fail(message):
    errors.append(message)


def warn(message):
    warnings.append(message)


def png_info(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    color_type = data[25]
    has_trns = b"tRNS" in data
    has_alpha = color_type in (4, 6) or has_trns
    return width, height, color_type, has_alpha


def check_icon():
    if not os.path.isfile(ICON):
        fail("icon is missing: %s" % os.path.relpath(ICON, ROOT))
        return
    try:
        width, height, color_type, has_alpha = png_info(ICON)
    except Exception as error:  # noqa: BLE001 - report any broken file as a check error
        fail("icon cannot be read as PNG: %s" % error)
        return
    if (width, height) != (1024, 1024):
        fail("icon is %dx%d, expected 1024x1024" % (width, height))
    if has_alpha:
        fail("icon has an alpha channel (PNG color type %d); App Store icons must be opaque RGB" % color_type)
    print("icon      : %dx%d, color type %d, alpha %s" % (width, height, color_type, "yes" if has_alpha else "no"))

    if not os.path.isfile(ICON_CONTENTS):
        fail("asset catalog Contents.json is missing")
    else:
        try:
            with open(ICON_CONTENTS, encoding="utf-8") as handle:
                contents = json.load(handle)
            filenames = [image.get("filename") for image in contents.get("images", [])]
            if "Wraithgram.png" not in filenames:
                fail("asset catalog does not reference Wraithgram.png")
        except Exception as error:  # noqa: BLE001
            fail("asset catalog Contents.json is invalid: %s" % error)


def check_app_name():
    if not os.path.isfile(BUILD):
        fail("Telegram/BUILD is missing")
        return
    with open(BUILD, encoding="utf-8") as handle:
        build = handle.read()
    display_names = re.findall(r"<string>(Wraithgram)</string>", build)
    if display_names.count("Wraithgram") < 3:
        fail("Telegram/BUILD does not set Wraithgram as the app/extension name")
    if 'bundle_name = "Wraithgram"' not in build:
        fail("Telegram/BUILD does not set bundle_name to Wraithgram")
    print("app name  : %d Wraithgram display/name entries" % display_names.count("Wraithgram"))


def check_string_tables():
    checked = 0
    for path in glob.glob(os.path.join(STRINGS_DIR, "*", "*.json")):
        try:
            with open(path, encoding="utf-8") as handle:
                json.load(handle)
        except Exception as error:  # noqa: BLE001
            fail("%s: invalid JSON: %s" % (os.path.relpath(path, ROOT), error))
            continue
        checked += 1
    print("strings   : %d JSON tables checked" % checked)


def check_user_visible_literals():
    expected = [
        (os.path.join(ROOT, "Wraithgram", "WGCore", "Sources", "Network", "WGNetwork.swift"), "Wraithgram"),
        (os.path.join(ROOT, "Wraithgram", "WGCore", "Tests", "WGNetworkTests.swift"), "Wraithgram"),
        (
            os.path.join(
                ROOT, "Wraithgram", "Features", "Interface", "Sources", "IslandBadge", "WGBadgeStudio.swift"
            ),
            "Wraithgram",
        ),
        (
            os.path.join(
                ROOT, "Wraithgram", "Features", "Vless", "Sources", "Engine", "WGVlessNetwork.swift"
            ),
            "Wraithgram",
        ),
    ]
    for path, name in expected:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if '"%s"' % name not in text and '"%s/' % name not in text:
            warn("%s does not contain the %s literal" % (os.path.relpath(path, ROOT), name))


def run_string_check():
    if not os.path.isfile(CHECK):
        fail("Wraithgram/Strings/check.py is missing")
        return
    result = subprocess.run(
        [sys.executable, CHECK, "--no-upstream", "--allow-unused"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    output = (result.stdout + result.stderr).strip()
    for line in output.splitlines():
        if line.startswith("error:"):
            fail("strings check: %s" % line[6:].strip())
        elif line.startswith("warning:"):
            warn("strings check: %s" % line[8:].strip())
    if result.returncode != 0 and not any("strings check:" in item for item in errors):
        fail("Wraithgram/Strings/check.py failed with exit code %d" % result.returncode)
    print("check.py  : exit %d" % result.returncode)


def main():
    print("Wraithgram branding check (%s)\n" % ROOT)
    check_icon()
    check_app_name()
    check_string_tables()
    check_user_visible_literals()
    run_string_check()

    print()
    for message in warnings:
        print("WARNING: %s" % message)
    if errors:
        for message in errors:
            print("ERROR: %s" % message)
        print("\nFAILED: %d error(s)" % len(errors))
        return 1

    print("OK: name, icon and string tables are consistent.")
    print()
    print("Build commands (macOS with Xcode):")
    print("  build-system/WGBuild.sh                  # simulator build")
    print("  build-system/WGBuildRelease.sh 1         # signed iPhone IPA")
    return 0


if __name__ == "__main__":
    sys.exit(main())
