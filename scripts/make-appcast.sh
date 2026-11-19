#!/bin/zsh
# Sign a release DMG for Sparkle and write build/dist/appcast.xml describing it.
#
#   SPARKLE_ED_PRIVATE_KEY=… VERSION=1.2.0 BUILD=42 ./scripts/make-appcast.sh build/dist/Murmur-1.2.0.dmg
#   SPARKLE_KEYCHAIN_ACCOUNT=sparkle-murmur …   # locally: use the key in the login keychain instead
#
# The app reads the feed from the latest GitHub Release (SUFeedURL in Info.plist), so each release
# carries an appcast with just its own item. Sparkle compares sparkle:version against CFBundleVersion
# (the CI run number), so it must keep increasing.
# AIDEV-NOTE: the DMG must already be notarized + stapled; signing it afterwards would break the EdDSA signature.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
DMG=${1:?usage: make-appcast.sh <dmg>}
[[ -f $DMG ]] || { echo "no such file: $DMG"; exit 1; }
VERSION=${VERSION:?set VERSION}
BUILD=${BUILD:?set BUILD}
REPO=${GITHUB_REPOSITORY:-jmaddington/murmur}
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
BIN=$(scripts/ci/sparkle-tools.sh)

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEYFILE=$(mktemp); chmod 600 "$KEYFILE"
  trap 'rm -f "${KEYFILE:?}"' EXIT
  print -r -- "$SPARKLE_ED_PRIVATE_KEY" > "$KEYFILE"
  SIG=$("$BIN/sign_update" --ed-key-file "$KEYFILE" "$DMG")
elif [[ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]]; then
  SIG=$("$BIN/sign_update" --account "$SPARKLE_KEYCHAIN_ACCOUNT" "$DMG")
else
  annotate error "Sparkle key missing" "Set SPARKLE_ED_PRIVATE_KEY (CI secret) or SPARKLE_KEYCHAIN_ACCOUNT (local)."
  echo "no Sparkle signing key"; exit 1
fi
# sign_update prints: sparkle:edSignature="…" length="…"
[[ $SIG == *'sparkle:edSignature="'*'length="'* ]] || { annotate error "sign_update failed" "$SIG"; echo "$SIG"; exit 1; }

NAME=${DMG:t}
URL="https://github.com/$REPO/releases/download/v$VERSION/$NAME"
NOTES="https://github.com/$REPO/releases/tag/v$VERSION"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
OUT=${DMG:h}/appcast.xml
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Murmur</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Murmur $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Murmur $VERSION is available. <a href="$NOTES">Release notes</a></p>]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "✓ $OUT (build $BUILD → $URL)"
