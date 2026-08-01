#!/usr/bin/env bash
# Build orchestration: Rust core → (later) xcframework → Swift app.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building Rust core"
(cd core/mediacore && cargo build --release)

echo "==> Building macOS app"
(cd apps/macos && swift build -c release)

echo "Done. Run with: swift run --package-path apps/macos"
