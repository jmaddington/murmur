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
# UI sounds (regenerate with: swift scripts/make-sounds.swift Resources/Sounds)
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"

# Sparkle (auto-update) ships as a binary xcframework via SwiftPM; embed it next to the executable.
SPARKLE_FW=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework 2>/dev/null | head -1)
[[ -d "$SPARKLE_FW" ]] || { annotate error "Sparkle missing" "Sparkle.framework not found under .build/artifacts"; echo "✗ Sparkle.framework not found"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Prefer an explicit identity, then any Developer ID in the keychain, else ad-hoc.
IDENTITY=${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}

# AIDEV-NOTE: sign Sparkle inside-out (XPCs, Autoupdate, Updater.app, framework) BEFORE the app; never --deep.
# Order and flags follow Sparkle's "Distributing outside Xcode" docs.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_sparkle() {   # $1 = identity ("-" for ad-hoc)
  local ts=(); [[ "$1" != "-" ]] && ts=(--timestamp)
  step "Signing Sparkle Installer.xpc" codesign -f -s "$1" -o runtime $ts "$SP/XPCServices/Installer.xpc"
  step "Signing Sparkle Downloader.xpc" codesign -f -s "$1" -o runtime $ts --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  step "Signing Sparkle Autoupdate" codesign -f -s "$1" -o runtime $ts "$SP/Autoupdate"
  step "Signing Sparkle Updater.app" codesign -f -s "$1" -o runtime $ts "$SP/Updater.app"
  step "Signing Sparkle.framework" codesign -f -s "$1" -o runtime $ts "$APP/Contents/Frameworks/Sparkle.framework"
}
sign_sparkle "${IDENTITY:--}"

if [[ -n "$IDENTITY" ]]; then
  step "Signing Murmur.app" codesign --force --options runtime --timestamp --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
  step "Verifying signature" codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --options runtime --entitlements Resources/Murmur.entitlements --sign - "$APP"
fi
echo "✓ $APP  (v$VERSION, signed: ${IDENTITY:-ad-hoc})"
