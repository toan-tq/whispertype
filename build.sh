#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build-release"

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
echo "Build complete: $BUILD_DIR/Whispertype.app"
