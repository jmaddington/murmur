#!/bin/zsh
# CI: load Developer ID certificates (base64 .p12 secrets) into a throwaway
# keychain and export the identity names for build.sh / package.sh.
set -euo pipefail
: "${RUNNER_TEMP:?}"
KC="$RUNNER_TEMP/murmur-signing.keychain-db"
KC_PASS=$(uuidgen)
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"

import() {   # $1 = base64 p12, $2 = password
  local f="$RUNNER_TEMP/cert-$RANDOM.p12"
  echo "$1" | base64 --decode > "$f"
  security import "$f" -k "$KC" -P "$2" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/pkgbuild
  rm -f "$f"
}
[[ -n "${DEVELOPER_ID_APP_P12:-}" ]] && import "$DEVELOPER_ID_APP_P12" "$DEVELOPER_ID_APP_PASSWORD"
[[ -n "${DEVELOPER_ID_INSTALLER_P12:-}" ]] && import "$DEVELOPER_ID_INSTALLER_P12" "$DEVELOPER_ID_INSTALLER_PASSWORD"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

APP_ID=$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
PKG_ID=$(security find-identity -v "$KC" | awk -F'"' '/Developer ID Installer/ {print $2; exit}')
echo "MURMUR_SIGN_IDENTITY=$APP_ID" >> "$GITHUB_ENV"
echo "MURMUR_INSTALLER_IDENTITY=$PKG_ID" >> "$GITHUB_ENV"

if [[ -n "${ASC_API_KEY_P8:-}" ]]; then
  echo "$ASC_API_KEY_P8" > "$RUNNER_TEMP/AuthKey.p8"
  { echo "NOTARY_KEY_PATH=$RUNNER_TEMP/AuthKey.p8"
    echo "NOTARY_KEY_ID=$ASC_API_KEY_ID"
    echo "NOTARY_ISSUER=$ASC_API_ISSUER_ID"; } >> "$GITHUB_ENV"
fi
echo "Signing: ${APP_ID:-none} | Installer: ${PKG_ID:-none} | Notary: ${ASC_API_KEY_ID:-none}"
