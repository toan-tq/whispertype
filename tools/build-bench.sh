#!/bin/bash
# Build whisper.cpp's whisper-server (and quantize) from the submodule for tools/bench_local.py.
# Same whisper.cpp revision and Apple Silicon settings as the app (Metal, Accelerate), so the
# numbers match what the app would do. Output: build-bench/bin/
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/external/whisper.cpp"
BUILD="$PROJECT_DIR/build-bench"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
    git -C "$PROJECT_DIR" submodule update --init external/whisper.cpp
fi

EXTRA=()
if [ "$(uname)" = "Darwin" ]; then
    EXTRA+=(-DGGML_METAL=ON -DGGML_ACCELERATE=ON -DGGML_NATIVE=ON -DCMAKE_OSX_ARCHITECTURES=arm64)
    EXTRA+=(-DCMAKE_OSX_SYSROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}")
fi

cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_SDL2=OFF -DBUILD_SHARED_LIBS=OFF "${EXTRA[@]}"

JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc) )
cmake --build "$BUILD" --config Release -j"$JOBS" --target whisper-server whisper-quantize

echo ""
echo "Built: $BUILD/bin/whisper-server"
echo "       $BUILD/bin/whisper-quantize   (e.g. whisper-quantize ggml-model.bin ggml-model-q5_0.bin q5_0)"
