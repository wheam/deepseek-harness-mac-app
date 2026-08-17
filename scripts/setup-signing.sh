#!/usr/bin/env bash
# One-time local setup for the stable code-signing identity.
#
# Creates a dedicated keychain, imports a PKCS#12 bundle (certificate +
# private key, CN "DeepSeek Harness Dev"), allows codesign to use the key
# non-interactively, and adds the keychain to the user's search list.
# Afterwards build.sh signs every build with this fixed identity, so macOS
# remembers privacy (TCC) choices across rebuilds and app updates.
#
# IMPORTANT: this identity is self-signed. It keeps TCC grants stable, but
# it does NOT pass Gatekeeper - apps downloaded from the internet still show
# the "unidentified developer" warning until the user right-clicks → Open
# (see README). Only a paid Apple Developer ID certificate + notarization
# removes that warning entirely.
#
# Usage: ./scripts/setup-signing.sh <identity.p12> <password>
# Generate the p12 like this (OpenSSL, once, from the repository root):
#   openssl req -x509 -new -newkey rsa:2048 -nodes \
#     -keyout key.pem -out cert.pem -days 3650 -config scripts/signing.cnf
#   openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem \
#     -passout pass:<password> -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
#
# The cert must carry the Code Signing extended key usage (1.3.6.1.5.5.7.3.3);
# scripts/signing.cnf adds it, and this script refuses to install a
# certificate without it (build.sh would reject it too).
set -euo pipefail

P12_PATH="${1:?usage: setup-signing.sh <identity.p12> <password>}"
P12_PASSWORD="${2:?usage: setup-signing.sh <identity.p12> <password>}"
KEYCHAIN="$HOME/Library/Keychains/dsh-signing.keychain-db"
KEYCHAIN_PASSWORD="dshdev"

rm -f "$KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12_PATH" -P "$P12_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | awk -F'"' 'NF>1 {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "error: no codesigning identity imported into $KEYCHAIN" >&2
  exit 1
fi
if ! security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" 2>/dev/null \
     | openssl x509 -noout -text 2>/dev/null | grep -Eqi "code signing"; then
  echo "error: certificate \"$IDENTITY\" lacks the Code Signing extended key usage;" >&2
  echo "       regenerate the p12 with scripts/signing.cnf (see the comment above)" >&2
  exit 1
fi

echo "signing identity \"$IDENTITY\" (Code Signing EKU verified) installed into $KEYCHAIN"
security find-identity "$KEYCHAIN" 2>/dev/null | tail -2 || true
