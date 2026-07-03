#!/bin/bash
# Packages dist/LocalFlow.app into dist/LocalFlow-<version>.dmg for team
# distribution (version read from the app's CFBundleShortVersionString).
#
# If vendor/whisper-bin/whisper-server exists (built by
# scripts/bundle_whisper.sh), it is embedded into the app at
# Contents/Resources/bin/ and the bundle is re-signed, so teammates don't
# need Homebrew or whisper-cpp.
#
# Usage: scripts/make_dmg.sh   (run scripts/make_app.sh first)
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/LocalFlow.app"
VENDORED_SERVER="vendor/whisper-bin/whisper-server"

[ -d "$APP" ] || { echo "ERROR: $APP not found — run scripts/make_app.sh first" >&2; exit 1; }

# --- embed whisper-server ----------------------------------------------------
if [ -f "$VENDORED_SERVER" ]; then
    echo "==> Embedding whisper-server into $APP/Contents/Resources/bin/"
    mkdir -p "$APP/Contents/Resources/bin"
    cp "$VENDORED_SERVER" "$APP/Contents/Resources/bin/whisper-server"
    # Metal shader files only exist when the build didn't embed them into the
    # binary; they must travel next to it.
    find vendor/whisper-bin -maxdepth 1 \( -name '*.metallib' -o -name 'ggml-metal.metal' \) \
        -exec cp {} "$APP/Contents/Resources/bin/" \;

    # Same identity pick as scripts/make_app.sh: a stable local cert when one
    # exists, otherwise ad-hoc. Nested executables must be signed before the
    # outer bundle, and adding Resources content breaks the old seal, so the
    # bundle is force-re-signed afterwards.
    IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Code Signing|Development|LocalFlow/ {print $2; exit}')}"
    codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/bin/whisper-server"
    codesign --force --sign "${IDENTITY:--}" "$APP"
    codesign --verify --strict "$APP"
    echo "==> Re-signed with: ${IDENTITY:-ad-hoc}"
else
    echo "==> NOTE: $VENDORED_SERVER not found — DMG will ship WITHOUT an embedded"
    echo "    whisper-server (teammates would need scripts/setup.sh). Run"
    echo "    scripts/bundle_whisper.sh first to produce a self-contained app."
fi

# --- create DMG --------------------------------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/LocalFlow-$VERSION.dmg"

STAGING="$(mktemp -d /tmp/localflow-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

# ditto (not cp) preserves the code-signature metadata of the bundle.
ditto "$APP" "$STAGING/LocalFlow.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "LocalFlow $VERSION" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "    Verify locally: hdiutil attach '$DMG'"
