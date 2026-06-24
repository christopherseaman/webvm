#!/bin/bash
# Archive the WebVM iOS app (Release) and upload it to TestFlight using an
# App Store Connect API key. Same automatic-signing + .p8 chain as the sibling
# reference projects. The app record for the bundle id must already exist in
# App Store Connect — this uploads a build, it does not create the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# App Store Connect auth (identifiers, not secrets) from .asc.env (gitignored).
if [[ -f "$SCRIPT_DIR/.asc.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.asc.env"
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID in ios/.asc.env (see .asc.env.example)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in ios/.asc.env}"
: "${ASC_TEAM_ID:?set ASC_TEAM_ID in ios/.asc.env}"

SCHEME="WebVM"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ARCHIVE="$SCRIPT_DIR/.build-xcode/WebVM.xcarchive"
EXPORT_DIR="$SCRIPT_DIR/.build-xcode/export"
EXPORT_OPTS="$SCRIPT_DIR/.build-xcode/ExportOptions.plist"

[[ -f "$KEY_PATH" ]] || { echo "ERROR: ASC key not found: $KEY_PATH" >&2; exit 1; }

echo "==> [1/5] Stage web bundle + disk image"
"$SCRIPT_DIR/stage.sh"

echo "==> [2/5] Generate Xcode project"
xcodegen generate

echo "==> [3/5] Stamp build number (unix timestamp -> unique, increasing)"
BUILD_NUM="$(date +%s)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$SCRIPT_DIR/App/Info.plist"
echo "    CFBundleVersion=$BUILD_NUM"

echo "==> [4/5] Archive (Release, device, automatic signing)"
xcodebuild \
  -project WebVM.xcodeproj \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" \
  archive

echo "==> [5/5] Export + upload to TestFlight"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>${ASC_TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

# /usr/bin first so Xcode uses system rsync (a Homebrew rsync on PATH breaks -exportArchive).
PATH=/usr/bin:$PATH xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Uploaded build $BUILD_NUM to TestFlight (bundle app.ish.iSH.KTGSS9PB3A). Processing takes a few minutes."
