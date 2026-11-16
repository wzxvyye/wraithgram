"""Check every .xcassets in the repo for files that Contents.json does not reference.

actool fails with `The app icon set "X" has an unassigned child` when a file sits
in a set folder without being listed in that folder's Contents.json. This catches
leftovers from renames (e.g. Wraithgram.png next to Wraithgram.png).

Usage: python tools/check_asset_catalogs.py [repo_root]
"""
import json
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SKIP_DIRS = {".git", "bazel-bin", "bazel-out", "bazel-testlogs", "build-output", "node_modules"}

problems = []
checked = 0

for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    if not dirpath.endswith(".xcassets"):
        continue
    for set_name in sorted(os.listdir(dirpath)):
        set_path = os.path.join(dirpath, set_name)
        if not os.path.isdir(set_path):
            continue
        contents_path = os.path.join(set_path, "Contents.json")
        if not os.path.isfile(contents_path):
            continue
        checked += 1
        with open(contents_path, "r", encoding="utf-8") as f:
            try:
                data = json.load(f)
            except Exception as exc:  # noqa: BLE001
                problems.append((set_path, f"Contents.json is not valid JSON: {exc}"))
                continue
        referenced = set()
        for key in ("images", "properties", "data", "layers"):
            for entry in data.get(key) or []:
                if isinstance(entry, dict):
                    for value in entry.values():
                        if isinstance(value, str) and value.endswith(".png"):
                            referenced.add(value)
                        elif isinstance(value, str) and "." in value:
                            referenced.add(value)
                elif isinstance(entry, str):
                    referenced.add(entry)
        # Filenames only (some entries use subpaths).
        referenced_names = {os.path.basename(r) for r in referenced}
        for name in sorted(os.listdir(set_path)):
            if name == "Contents.json" or name.startswith("."):
                continue
            if os.path.isdir(os.path.join(set_path, name)):
                continue
            if name not in referenced_names:
                problems.append((set_path, f"unassigned file: {name}"))

print(f"checked {checked} asset-set folders under {ROOT}")
if problems:
    print(f"PROBLEMS: {len(problems)}")
    for path, msg in problems:
        print(f"  {os.path.relpath(path, ROOT)}: {msg}")
    sys.exit(1)
print("OK")
