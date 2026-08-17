#!/usr/bin/env bash
# Build the DeepSeek Harness macOS shell into dist/"DeepSeek Harness.app".
#
# Requirements: Xcode command line tools (swift + iconutil). No third-party
# dependencies. The result is signed with the fixed self-signed identity
# "DeepSeek Harness Dev" when available, otherwise ad-hoc; neither scheme
# passes Gatekeeper for downloaded apps (see README).
#
# Set UNIVERSAL=1 to build a universal binary (Apple Silicon + Intel), used
# by the GitHub Actions release workflow.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DeepSeek Harness"
BIN_NAME="DeepSeekHarness"
OUT="dist/$APP_NAME.app"

# --disable-sandbox: SwiftPM's manifest sandbox (sandbox-exec) fails with
# "sandbox_apply: Operation not permitted" on newer macOS (15+); the package
# has no dependencies or plugins, so the sandbox adds nothing here.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "==> swift build -c release --arch arm64 --arch x86_64"
  swift build -c release --disable-sandbox --product "$BIN_NAME" --arch arm64 --arch x86_64
  # Multi-arch products land under .build/apple/Products/Release.
  BIN_PATH=".build/apple/Products/Release/$BIN_NAME"
else
  echo "==> swift build -c release"
  swift build -c release --disable-sandbox --product "$BIN_NAME"
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
# Stamp the build time (ISO 8601 UTC): the self-updater compares it with
# the rolling GitHub release's publish time.
/usr/libexec/PlistBuddy -c "Delete :DSHBuildDate" "$OUT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :DSHBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OUT/Contents/Info.plist"

if command -v swift >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET=".build/AppIcon.iconset"
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
  echo "==> icon generated"
else
  echo "==> warning: swift/iconutil missing, skipping icon"
fi

echo "==> codesign"
# Signing policy (identical to GitHub Actions): sign with the fixed
# self-signed identity "DeepSeek Harness Dev" when its keychain is present
# (set up once via scripts/setup-signing.sh), otherwise fall back to ad-hoc.
# A fixed identity keeps macOS privacy (TCC) grants stable across rebuilds
# and auto-updates. Neither scheme passes Gatekeeper for downloaded apps -
# only a Developer ID certificate + notarization does (see README).
SIGNING_KEYCHAIN="${CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/dsh-signing.keychain-db}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-DeepSeek Harness Dev}"
SIGNED_WITH="ad-hoc"
# The certificate embedded in the bundle must carry the Code Signing
# extended key usage (1.3.6.1.5.5.7.3.3); without it Gatekeeper can report
# a quarantined copy as "damaged" instead of merely "unidentified
# developer". Check the actual signed output (codesign --extract-certificates
# + openssl) rather than the keychain, where `security find-certificate` is
# unreliable across macOS versions.
has_code_signing_eku() {
  local dir rc app
  app="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
  dir="$(mktemp -d)"
  ( cd "$dir" \
      && codesign -d --extract-certificates "$app" >/dev/null 2>&1 \
      && openssl x509 -inform DER -in codesign0 -noout -purpose 2>/dev/null \
         | grep -q "Code signing : Yes" )
  rc=$?
  rm -rf "$dir"
  return $rc
}
if [ -n "$SIGNING_IDENTITY" ] && [ -f "$SIGNING_KEYCHAIN" ]; then
  security unlock-keychain -p "${CODESIGN_KEYCHAIN_PASSWORD:-dshdev}" "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  if ! codesign --force --deep --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" "$OUT" >/dev/null 2>&1 \
       || ! codesign --verify --deep --strict "$OUT" >/dev/null 2>&1; then
    echo "warning: signing with \"$SIGNING_IDENTITY\" failed, falling back to ad-hoc"
  elif ! has_code_signing_eku "$OUT"; then
    echo "warning: \"$SIGNING_IDENTITY\" certificate lacks the Code Signing EKU, falling back to ad-hoc"
  else
    SIGNED_WITH="$SIGNING_IDENTITY"
  fi
fi
if [ "$SIGNED_WITH" = "ad-hoc" ]; then
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || echo "warning: codesign skipped"
fi
echo "    signed with: $SIGNED_WITH"

echo "==> done: $OUT"
echo "    run it with:  open \"$OUT\""
