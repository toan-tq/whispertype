#!/bin/bash
set -e

# Usage: ./build.sh [--no-install]
#   Default: build, then move the bundle into /Applications and relaunch it, so the machine
#   only ever holds one Whispertype.app. Two copies share the bundle id com.tqt.whispertype,
#   which puts both in Spotlight and lets LaunchServices start the wrong one (whose ad-hoc
#   cdhash TCC does not recognise).
#   --no-install: build only; the bundle stays in build-release/.
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        *) echo "Unknown option: $arg" >&2; echo "Usage: $0 [--no-install]" >&2; exit 1 ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build-release"
BUILT_APP="$BUILD_DIR/Whispertype.app"
INSTALLED_APP="/Applications/Whispertype.app"
BUNDLE_ID="com.tqt.whispertype"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "Build dir: $BUILD_DIR"
echo ""

mkdir -p "$BUILD_DIR"

# Pin the SDK to the one shipped with the selected Xcode. Without this, clang picks the
# Command Line Tools SDK, and after a macOS upgrade that SDK can be newer than Xcode's
# linker understands (macOS 27 CLT SDK + Xcode 26 ld fails with "unknown architecture").
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
echo "SDK: $SDK (deployment target $TARGET)"

cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
    -DGGML_NATIVE=ON \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    -DCODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cmake --build "$BUILD_DIR" --config Release -j$(sysctl -n hw.ncpu)

echo ""
if [ "$INSTALL" = 0 ]; then
    echo "Build complete: $BUILT_APP"
    echo "Not installed. This is a second copy of $BUNDLE_ID if one is already in /Applications;"
    echo "run ./build.sh without --no-install to move it there."
    exit 0
fi

# Quit the running copy (from any path) before replacing it.
if pgrep -xq Whispertype; then
    echo "Quitting running Whispertype..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -xq Whispertype || break; sleep 0.1; done
    if pgrep -xq Whispertype; then
        pkill -x Whispertype || true
        for _ in {1..20}; do pgrep -xq Whispertype || break; sleep 0.1; done
    fi
fi

# Replace the whole bundle rather than copying over it: overwriting a signed binary in
# place keeps the kernel's cached signature for that file and can get the app killed at
# launch, and a merge copy leaves stale files from the old bundle behind.
echo "Installing to $INSTALLED_APP..."
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
rm -rf "$INSTALLED_APP"
mv "$BUILT_APP" "$INSTALLED_APP"
"$LSREGISTER" -f "$INSTALLED_APP"

open "$INSTALLED_APP"
echo "Installed and launched: $INSTALLED_APP"

if [ "${CODESIGN_IDENTITY:--}" = "-" ]; then
    echo ""
    echo "Ad-hoc signed: macOS sees this as a new app, so re-grant Accessibility and Microphone"
    echo "(see README, \"Permissions survive rebuilds only with a stable signing identity\")."
fi
