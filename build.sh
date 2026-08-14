#!/usr/bin/env bash
# Build the DeepSeek Harness macOS shell into dist/"DeepSeek Harness.app".
#
# Requirements: Xcode command line tools (swift + iconutil). No third-party
# dependencies. The result is ad-hoc signed so it runs locally.
#
# Set UNIVERSAL=1 to build a universal binary (Apple Silicon + Intel), used
# by the GitHub Actions release workflow.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DeepSeek Harness"
BIN_NAME="DeepSeekHarness"
OUT="dist/$APP_NAME.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "==> swift build -c release --arch arm64 --arch x86_64"
  swift build -c release --product "$BIN_NAME" --arch arm64 --arch x86_64
  # Multi-arch products land under .build/apple/Products/Release.
  BIN_PATH=".build/apple/Products/Release/$BIN_NAME"
else
  echo "==> swift build -c release"
  swift build -c release --product "$BIN_NAME"
  BIN_PATH=".build/release/$BIN_NAME"
fi
if [ ! -f "$BIN_PATH" ]; then
  BIN_PATH=$(find .build -type f -name "$BIN_NAME" | head -1)
fi
[ -n "${BIN_PATH:-}" ] && [ -f "$BIN_PATH" ] || { echo "error: $BIN_NAME binary not found after build" >&2; exit 1; }
echo "==> binary: $BIN_PATH ($(lipo -info "$BIN_PATH" | head -1 | cut -d: -f3 | tr -d ' '))"

echo "==> assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_PATH" "$OUT/Contents/MacOS/$BIN_NAME"
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
