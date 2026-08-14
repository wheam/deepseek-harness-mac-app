#!/usr/bin/env bash
# Build the DeepSeek Harness macOS shell into dist/"DeepSeek Harness.app".
#
# Requirements: Xcode command line tools (swift + iconutil). No third-party
# dependencies. The result is ad-hoc signed so it runs locally.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DeepSeek Harness"
BIN_NAME="DeepSeekHarness"
OUT="dist/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release --product "$BIN_NAME"

echo "==> assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/$BIN_NAME" "$OUT/Contents/MacOS/$BIN_NAME"
cp Info.plist "$OUT/Contents/Info.plist"

if command -v swift >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET=".build/AppIcon.iconset"
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
  echo "==> icon generated"
else
  echo "==> warning: swift/iconutil missing, skipping icon"
fi

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || echo "warning: codesign skipped"

echo "==> done: $OUT"
echo "    run it with:  open \"$OUT\""
