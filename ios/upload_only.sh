#!/bin/bash
# Upload the ALREADY-BUILT archive (.build-xcode/WebVM.xcarchive) to TestFlight.
# Reuses the archive staged this session — does NOT rebuild/re-stamp. Run via:
#   ! bash ios/upload_only.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source .asc.env
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ARCHIVE="$SCRIPT_DIR/.build-xcode/WebVM.xcarchive"
EXPORT_DIR="$SCRIPT_DIR/.build-xcode/export"
EXPORT_OPTS="$SCRIPT_DIR/.build-xcode/ExportOptions.plist"

[[ -d "$ARCHIVE" ]] || { echo "ERROR: archive not found: $ARCHIVE (run the build first)"; exit 1; }
echo "==> Uploading $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist) (archive: $ARCHIVE)"

cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>${ASC_TEAM_ID}</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

# /usr/bin first so Xcode uses system rsync (a Homebrew rsync breaks -exportArchive).
PATH=/usr/bin:$PATH xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Uploaded to TestFlight (bundle app.ish.iSH.KTGSS9PB3A / Hyper-Cube). Processing takes a few minutes."
