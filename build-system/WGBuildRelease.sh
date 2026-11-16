#!/bin/bash
# Build a distribution-signed Wraithgram IPA for TestFlight (release_arm64).
#
#   build-system/WGBuildRelease.sh <buildNumber> [extra Make.py args...]
#
# Config:  build-system/wraithgram-configuration.json (gitignored keys, see WGBuild.sh).
# Signing: build-system/wraithgram-codesigning/{certs,profiles} — App Store distribution
#          certificate (.p12, empty password, as Make.py imports it) and profiles for
#          the bundle_id from the config and its extensions. Gitignored; never commit it.
# Output:  build-output/ipa/Wraithgram.ipa
#
# The build number must be higher than any build already uploaded for this version.

set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${1:-}"
[ -n "$BUILD_NUMBER" ] || { echo "usage: $0 <buildNumber> [extra Make.py args...]" >&2; exit 2; }
shift

CONFIG="build-system/wraithgram-configuration.json"
CODESIGN="build-system/wraithgram-codesigning"
OUTPUT_DIR="build-output/ipa"
[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG is missing." >&2; exit 1; }
[ -d "$CODESIGN/certs" ] && [ -d "$CODESIGN/profiles" ] || { echo "ERROR: $CODESIGN/{certs,profiles} is missing." >&2; exit 1; }

LOG="${WG_BUILD_LOG:-/tmp/gg-build-release.log}"
echo "config     : $CONFIG"
echo "signing    : $CODESIGN"
echo "build      : $BUILD_NUMBER (release_arm64)"
echo "log        : $LOG"
echo

build-system/WGXcodeConfig.sh || exit 1
# Patches inside submodules (rules_apple, tgcalls) — same as WGBuild.sh.
WG_PATCHES_ONLY=1 build-system/WGBuild.sh || exit 1

mkdir -p "$OUTPUT_DIR"
python3 build-system/Make/Make.py --overrideXcodeVersion \
    --cacheDir ~/telegram-bazel-cache \
    build \
    --configurationPath "$CONFIG" \
    --codesigningInformationPath "$CODESIGN" \
    --buildNumber="$BUILD_NUMBER" --configuration=release_arm64 \
    --outputBuildArtifactsPath "$OUTPUT_DIR" \
    "$@" 2>&1 | tee "$LOG"

status=${PIPESTATUS[0]}
echo
if [ "$status" = "0" ] && [ -f "$OUTPUT_DIR/Telegram.ipa" ]; then
    mv -f "$OUTPUT_DIR/Telegram.ipa" "$OUTPUT_DIR/Wraithgram.ipa"
    echo "BUILD OK: $OUTPUT_DIR/Wraithgram.ipa"
else
    echo "BUILD FAILED (exit $status) — errors:"
    grep -E "^ERROR:|error: " "$LOG" | head -20
    [ "$status" = "0" ] && status=1
fi
exit "$status"
