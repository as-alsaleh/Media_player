#!/usr/bin/env bash
# Build mediacore as an xcframework + Swift bindings for macOS/iOS/iOS-sim.
set -euo pipefail
cd "$(dirname "$0")/../core/mediacore"
export PATH="$HOME/.cargo/bin:$PATH"

TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim)
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release --target "$t" --lib
done

OUT=../../build/mediacore
rm -rf "$OUT"
mkdir -p "$OUT/bindings" "$OUT/headers"

echo "==> Generating Swift bindings"
cargo run --release --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libmediacore.dylib \
  --language swift --out-dir "$OUT/bindings"

# Layout: header+modulemap per-slice for xcframework, swift file for the app.
cp "$OUT/bindings/mediacoreFFI.h" "$OUT/headers/"
cat > "$OUT/headers/module.modulemap" <<'EOF'
module mediacoreFFI {
    header "mediacoreFFI.h"
    export *
}
EOF

echo "==> Creating xcframework"
rm -rf "$OUT/Mediacore.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/libmediacore.a -headers "$OUT/headers" \
  -library target/aarch64-apple-ios/release/libmediacore.a -headers "$OUT/headers" \
  -library target/aarch64-apple-ios-sim/release/libmediacore.a -headers "$OUT/headers" \
  -library target/aarch64-apple-tvos/release/libmediacore.a -headers "$OUT/headers" \
  -library target/aarch64-apple-tvos-sim/release/libmediacore.a -headers "$OUT/headers" \
  -output "$OUT/Mediacore.xcframework"

echo "Done: build/mediacore/Mediacore.xcframework + bindings/mediacore.swift"
