#!/bin/zsh
# Emit a PPPC configuration profile that pre-approves Accessibility for Murmur,
# for deployment via Addigy / any MDM. (macOS never lets MDM pre-approve the
# microphone; users get one prompt for that.)
set -euo pipefail
APP=${1:-build/Murmur.app}
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
REQ=$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadDisplayName</key><string>Murmur — Privacy Preferences</string>
  <key>PayloadIdentifier</key><string>$BUNDLE_ID.pppc</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadScope</key><string>System</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
      <key>PayloadIdentifier</key><string>$BUNDLE_ID.pppc.tcc</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>Services</key>
      <dict>
        <key>Accessibility</key>
        <array>
          <dict>
            <key>Identifier</key><string>$BUNDLE_ID</string>
            <key>IdentifierType</key><string>bundleID</string>
            <key>CodeRequirement</key><string>$REQ</string>
            <key>Authorization</key><string>Allow</string>
            <key>Comment</key><string>Type dictated text into the focused app; detect the dictation key.</string>
          </dict>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
XML
