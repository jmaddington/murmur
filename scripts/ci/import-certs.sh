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

# Apple's Developer ID intermediates: without them the identity is untrusted and
# `find-identity -v` silently drops it.
for ca in DeveloperIDG2CA DeveloperIDCA; do
  curl -fsSL "https://www.apple.com/certificateauthority/$ca.cer" -o "$RUNNER_TEMP/$ca.cer" \
    && security import "$RUNNER_TEMP/$ca.cer" -k "$KC" >/dev/null 2>&1 || true
done

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
  # Accept the .p8 as pasted text or base64 of the file.
  if [[ "$ASC_API_KEY_P8" == *"BEGIN PRIVATE KEY"* ]]; then
    printf '%s\n' "$ASC_API_KEY_P8" > "$RUNNER_TEMP/AuthKey.p8"
  else
    echo "$ASC_API_KEY_P8" | base64 --decode > "$RUNNER_TEMP/AuthKey.p8" 2>/dev/null || printf '%s\n' "$ASC_API_KEY_P8" > "$RUNNER_TEMP/AuthKey.p8"
  fi
  # Validate the credentials now so a bad key fails here, legibly.
  if ! NOTARY_CHECK=$(xcrun notarytool history --key "$RUNNER_TEMP/AuthKey.p8" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" 2>&1 | tail -5); then
    echo "$NOTARY_CHECK"
    MSG=${NOTARY_CHECK//$'\n'/%0A}
    echo "::error title=Notary API key rejected::$MSG%0AKey file looks like PEM: $(grep -q 'BEGIN PRIVATE KEY' "$RUNNER_TEMP/AuthKey.p8" && echo yes || echo no), lines: $(wc -l < "$RUNNER_TEMP/AuthKey.p8" | tr -d ' ')"
    exit 1
  fi
  { echo "NOTARY_KEY_PATH=$RUNNER_TEMP/AuthKey.p8"
    echo "NOTARY_KEY_ID=$ASC_API_KEY_ID"
    echo "NOTARY_ISSUER=$ASC_API_ISSUER_ID"; } >> "$GITHUB_ENV"
fi
SUMMARY="App identity: ${APP_ID:-MISSING} · Installer identity: ${PKG_ID:-MISSING} · Notary key: ${ASC_API_KEY_ID:+set}${ASC_API_KEY_ID:-MISSING}"
echo "$SUMMARY"
echo "::notice title=Signing setup::$SUMMARY"
if [[ -z "$APP_ID" ]]; then
  echo "::group::Identities in signing keychain"; security find-identity "$KC"; echo "::endgroup::"
  echo "::error title=No valid Developer ID Application identity::Check DEVELOPER_ID_APP_P12 / DEVELOPER_ID_APP_PASSWORD. Identities seen: $(security find-identity "$KC" | grep -c ')') (valid: 0)"
  exit 1
fi
