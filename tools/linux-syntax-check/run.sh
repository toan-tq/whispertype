#!/bin/bash
# Syntax/type check of src/*.mm on a machine WITHOUT the macOS SDK (e.g. a Linux cloud
# session): clang -fsyntax-only against minimal hand-written stand-ins for the Apple
# headers in sdk/. Catches typos, wrong member names in our own code, ObjC++/ARC/block
# mistakes. It does NOT prove Apple API names or signatures are right (the stubs were
# written from memory) and it does not link. The real check is ./build.sh on a Mac.
#
# Usage: tools/linux-syntax-check/run.sh      (exit code 1 if any file has errors/warnings)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WHISPER="$ROOT/external/whisper.cpp"
if [ ! -f "$WHISPER/include/whisper.h" ]; then
    git -C "$ROOT" submodule update --init --depth 1 external/whisper.cpp || exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT"/src/*.h "$TMP"/
for f in "$ROOT"/src/*.mm; do
    # macOS pthread_setname_np takes one argument, glibc's takes two.
    sed 's/pthread_setname_np(/mac_pthread_setname_np(/' "$f" > "$TMP/$(basename "$f")"
done
status=0
for f in "$TMP"/*.mm; do
    out=$(clang++ -fsyntax-only -x objective-c++ -std=c++17 -fobjc-arc -fblocks \
          -fobjc-runtime=macosx-10.15 -Wall -Wextra -Wno-four-char-constants -Wno-multichar \
          -I"$HERE/sdk/inc" -I"$TMP" -I"$WHISPER/include" -I"$WHISPER/ggml/include" "$f" 2>&1 \
          | grep -E "error|warning")
    if [ -n "$out" ]; then
        echo "== $(basename "$f")"; echo "$out"; status=1
    else
        echo "ok  $(basename "$f")"
    fi
done
exit $status
