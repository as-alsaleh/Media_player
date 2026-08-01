#!/usr/bin/env bash
# Package the SwiftPM-built executable into MediaPlayer.app.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/../apps/macos"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/MediaPlayer"
BUNDLE_DIR=".build/MediaPlayer.app"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp Info.plist "$BUNDLE_DIR/Contents/Info.plist"
mkdir -p "$BUNDLE_DIR/Contents/Resources"
cp AppIcon.icns "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
cp "$BIN" "$BUNDLE_DIR/Contents/MacOS/MediaPlayer"

# Bundle the mediacored streamer helper (built by cargo).
(cd ../../core/mediacore && cargo build --release --bin mediacored)
cp ../../core/mediacore/target/release/mediacored "$BUNDLE_DIR/Contents/MacOS/mediacored"

# Dev bundle: resolve MPVKit frameworks from the SwiftPM build dir via rpath.
# (Distribution builds will embed properly-versioned frameworks instead.)
ARCH_DIR="$PWD/.build/arm64-apple-macosx/$CONFIG"
install_name_tool -add_rpath "$ARCH_DIR" \
  "$BUNDLE_DIR/Contents/MacOS/MediaPlayer"

codesign --force --sign - "$BUNDLE_DIR"
codesign --verify "$BUNDLE_DIR"
echo "Bundled: apps/macos/$BUNDLE_DIR"
