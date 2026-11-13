#!/bin/zsh
# Build Murmur.app: Rust core (static lib) → Swift app → signed bundle.
#
#   VERSION=1.2.0 BUILD=42 ./scripts/build.sh
#   MURMUR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-1}
export MACOSX_DEPLOYMENT_TARGET=26.0
source scripts/lib.sh

echo "▸ Rust core"
(cd core && cargo build --release --quiet)

echo "▸ Swift app ($CONFIG, v$VERSION build $BUILD)"
if ! LOG=$(swift build -c "$CONFIG" --arch arm64 2>&1); then
  ERRS=$(echo "$LOG" | grep -E "error:" | sed 's/\x1b\[[0-9;]*m//g' | sort -u)
  echo "$ERRS"; annotate error "Swift build failed" "$ERRS"
  echo "✗ Swift build failed"; exit 1
fi
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Murmur"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "▸ Icon"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer an explicit identity, then any Developer ID in the keychain, else ad-hoc.
IDENTITY=${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
if [[ -n "$IDENTITY" ]]; then
  step "Signing Murmur.app" codesign --force --options runtime --timestamp --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
  step "Verifying signature" codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --options runtime --entitlements Resources/Murmur.entitlements --sign - "$APP"
fi
echo "✓ $APP  (v$VERSION, signed: ${IDENTITY:-ad-hoc})"
