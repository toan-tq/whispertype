#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build-release"

echo "Build dir: $BUILD_DIR"
echo ""

mkdir -p "$BUILD_DIR"

cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_NATIVE=ON \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON

cmake --build "$BUILD_DIR" --config Release -j$(sysctl -n hw.ncpu)

echo ""
echo "Build complete: $BUILD_DIR/Whispertype.app"
