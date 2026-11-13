#!/bin/zsh
# Package build/Murmur.app into a DMG (drag-to-install) and a PKG (MDM / double-click),
# sign, notarize and staple when credentials are present, and write checksums.
#
# Env:
#   VERSION                     version string (default: from the app's Info.plist)
#   MURMUR_SIGN_IDENTITY        "Developer ID Application: …"  (signs the DMG)
#   MURMUR_INSTALLER_IDENTITY   "Developer ID Installer: …"    (signs the PKG)
#   NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER   App Store Connect API key → notarize
#   Requires: brew install create-dmg
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Murmur.app
[[ -d $APP ]] || { echo "run scripts/build.sh first"; exit 1; }
VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Contents/Info.plist)}
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $APP/Contents/Info.plist)
DIST=build/dist
rm -rf "$DIST" build/pkg build/art
mkdir -p "$DIST" build/pkg build/art
APP_ID=${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
PKG_ID=${MURMUR_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null | awk -F'"' '/Developer ID Installer/ {print $2; exit}')}

echo "▸ Installer artwork"
swift scripts/make-installer-art.swift build/art
tiffutil -cathidpicheck build/art/dmg-background.png build/art/dmg-background@2x.png -out build/art/dmg-background.tiff >/dev/null

echo "▸ DMG"
DMG="$DIST/Murmur-$VERSION.dmg"
# create-dmg lays the window out via Finder, which is what macOS 26 honours.
# 448 = 420pt of content + the title bar.
create-dmg --volname "Murmur" --volicon build/AppIcon.icns --background build/art/dmg-background.tiff \
  --window-pos 200 140 --window-size 660 448 --icon-size 112 --text-size 13 \
  --icon "Murmur.app" 178 196 --hide-extension "Murmur.app" --app-drop-link 482 196 \
  --no-internet-enable "$DMG" "$APP" >/dev/null
[[ -n "$APP_ID" ]] && codesign --force --timestamp --sign "$APP_ID" "$DMG"

echo "▸ PKG"
COMPONENT_PLIST=build/pkg/component.plist
cat > "$COMPONENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><false/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
  <key>RootRelativeBundlePath</key><string>Murmur.app</string>
</dict></array></plist>
PLIST
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Murmur.app"
pkgbuild --root "$STAGE" --component-plist "$COMPONENT_PLIST" --install-location /Applications \
  --identifier "$BUNDLE_ID" --version "$VERSION" --scripts scripts/pkg/scripts build/pkg/Murmur-component.pkg >/dev/null
sed "s/{{VERSION}}/$VERSION/g; s/{{BUNDLE_ID}}/$BUNDLE_ID/g" scripts/pkg/distribution.xml > build/pkg/distribution.xml
RES=build/pkg/resources; cp -R scripts/pkg/resources "$RES"; cp build/art/pkg-background*.png "$RES/"
PKG="$DIST/Murmur-$VERSION.pkg"
if [[ -n "$PKG_ID" ]]; then
  productbuild --distribution build/pkg/distribution.xml --resources "$RES" --package-path build/pkg --sign "$PKG_ID" --timestamp "$PKG" >/dev/null
else
  productbuild --distribution build/pkg/distribution.xml --resources "$RES" --package-path build/pkg "$PKG" >/dev/null
fi

if [[ -n "${NOTARY_KEY_PATH:-}" && -n "$APP_ID" ]]; then
  for f in "$DMG" "$PKG"; do
    [[ "$f" == "$PKG" && -z "$PKG_ID" ]] && continue
    echo "▸ Notarizing $(basename "$f")"
    xcrun notarytool submit "$f" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait --timeout 30m
    xcrun stapler staple "$f"
  done
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "▸ Skipping notarization (no Developer ID / API key)"
fi

echo "▸ MDM profile"
scripts/make-pppc.sh "$APP" > "$DIST/Murmur-PPPC.mobileconfig"

(cd "$DIST" && shasum -a 256 *.dmg *.pkg > SHA256SUMS.txt)
echo "✓ $(ls $DIST | tr '\n' ' ')"
