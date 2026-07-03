#!/bin/bash
# Builds a statically-linked whisper-server (Metal GPU, shader library embedded
# in the binary) into vendor/whisper-bin/, suitable for shipping inside
# LocalFlow.app/Contents/Resources/bin/ so teammates need no Homebrew install.
#
# Usage: scripts/bundle_whisper.sh
# Requires: Homebrew cmake (brew install cmake), git, Xcode CLT.
set -euo pipefail

cd "$(dirname "$0")/.."

# Pinned upstream release. Bump deliberately; delete vendor/whisper.cpp after
# changing so the source is re-cloned at the new tag.
WHISPER_TAG="v1.9.1"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp"

SRC_DIR="vendor/whisper.cpp"
BUILD_DIR="$SRC_DIR/build"
OUT_DIR="vendor/whisper-bin"

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }
command -v cmake >/dev/null 2>&1 || {
    echo "ERROR: cmake is required (brew install cmake)" >&2
    exit 1
}

# --- fetch source (shallow, pinned tag) ------------------------------------
if [ -d "$SRC_DIR/.git" ]; then
    CURRENT_TAG="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo "unknown")"
    if [ "$CURRENT_TAG" != "$WHISPER_TAG" ]; then
        echo "==> vendor/whisper.cpp is at $CURRENT_TAG, want $WHISPER_TAG — re-cloning"
        rm -rf "$SRC_DIR"
    else
        echo "==> whisper.cpp $WHISPER_TAG already cloned"
    fi
fi
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Cloning whisper.cpp $WHISPER_TAG (shallow)"
    git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$SRC_DIR"
fi

# --- configure ---------------------------------------------------------------
# BUILD_SHARED_LIBS=OFF   : link libwhisper/libggml statically — a lone binary,
#                           no @rpath dylibs to ship or re-sign.
# GGML_METAL=ON           : GPU inference via Metal (default on Apple Silicon,
#                           pinned explicitly so a default change upstream
#                           can't silently produce a CPU-only build).
# GGML_METAL_EMBED_LIBRARY=ON : compile the Metal shaders into the binary
#                           itself. Without this the binary loads
#                           default.metallib / ggml-metal.metal from disk at
#                           runtime and errors when relocated into an app
#                           bundle without those files.
# GGML_NATIVE=OFF         : don't tune for this build machine's CPU (-mcpu=
#                           native); newer M-series features (e.g. i8mm) would
#                           crash on a teammate's M1.
# WHISPER_BUILD_TESTS=OFF : server target only, keep the build lean.
echo "==> Configuring (static, Metal embedded)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF

echo "==> Building whisper-server"
NCPU="$(sysctl -n hw.ncpu)"
cmake --build "$BUILD_DIR" --config Release --target whisper-server -j "$NCPU"

# --- collect artifacts -------------------------------------------------------
BIN="$BUILD_DIR/bin/whisper-server"
[ -x "$BIN" ] || { echo "ERROR: build produced no $BIN" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/whisper-server"

# With GGML_METAL_EMBED_LIBRARY=ON no .metallib should be produced, but if a
# future tag flips that default, ship whatever Metal resources appear next to
# the binary rather than failing silently at runtime.
METAL_RESOURCES="$(find "$BUILD_DIR/bin" -maxdepth 1 \( -name '*.metallib' -o -name 'ggml-metal.metal' \) 2>/dev/null || true)"
if [ -n "$METAL_RESOURCES" ]; then
    echo "==> Copying Metal resources (shader library was NOT embedded):"
    echo "$METAL_RESOURCES"
    echo "$METAL_RESOURCES" | while IFS= read -r f; do cp "$f" "$OUT_DIR/"; done
fi

# --- verify ------------------------------------------------------------------
echo "==> Verifying no non-system dylib dependencies"
if otool -L "$OUT_DIR/whisper-server" | tail -n +2 | grep -vE '^\s+(/usr/lib|/System)' ; then
    echo "ERROR: whisper-server links non-system libraries (see above) — not static" >&2
    exit 1
fi

echo "==> Smoke test: whisper-server --help"
"$OUT_DIR/whisper-server" --help >/dev/null

echo "==> Done: $OUT_DIR/whisper-server ($(du -h "$OUT_DIR/whisper-server" | cut -f1 | tr -d ' '))"
echo "    whisper.cpp $WHISPER_TAG, static, Metal embedded."
echo "    scripts/make_dmg.sh will bundle it into LocalFlow.app/Contents/Resources/bin/"
