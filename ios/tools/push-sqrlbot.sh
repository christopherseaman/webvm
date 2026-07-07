#!/bin/bash
# Autonomous TestFlight push, runnable by the sqrlbot automation user with zero
# input from cseaman: works in a sqrlbot-owned clone (so the real repo's mixed
# build-dir ownership never blocks it) and MANUAL-signs with sqrlbot's own
# self-minted Apple Distribution cert + profile (Xcode automatic signing can't
# work for sqrlbot — see the webvm-sqrlbot-signing-autonomy memory).
#
# Usage:  ./push-sqrlbot.sh [branch]     (default branch: ios-app)
set -euo pipefail

SRC="/Users/cseaman/projects/webvm"
BRANCH="${1:-ios-app}"
BUILD_DIR="/Users/sqrlbot/webvm-push"
KEYCHAIN="webvm-sign.keychain"
KC_PW_FILE="/Users/sqrlbot/.webvm-sign-kc.pw"
SIGN_IDENTITY="Apple Distribution"
SIGN_PROFILE="WebVM sqrlbot AppStore"
BUNDLE_ID="app.ish.iSH.KTGSS9PB3A"
SCHEME="WebVM"

echo "==> [1/7] Refresh sqrlbot-owned working copy of '$BRANCH'"
if [ ! -d "$BUILD_DIR/.git" ]; then
  git clone "$SRC" "$BUILD_DIR"
fi
git -C "$BUILD_DIR" fetch "$SRC" "$BRANCH"
git -C "$BUILD_DIR" reset --hard FETCH_HEAD
echo "    at $(git -C "$BUILD_DIR" log --oneline -1)"

echo "==> [2/7] Ensure heavy gitignored deps + secrets (APFS-clone from source)"
[ -d "$BUILD_DIR/node_modules" ] || cp -Rc "$SRC/node_modules" "$BUILD_DIR/node_modules"
mkdir -p "$BUILD_DIR/custom-disk-images"
[ -f "$BUILD_DIR/custom-disk-images/debian_mini.ext2" ] || \
  cp -c "$SRC/custom-disk-images/debian_mini.ext2" "$BUILD_DIR/custom-disk-images/debian_mini.ext2"
cp "$SRC/ios/.asc.env" "$BUILD_DIR/ios/.asc.env"
[ -f "$SRC/ios/.network.env" ] && cp "$SRC/ios/.network.env" "$BUILD_DIR/ios/.network.env" || true

cd "$BUILD_DIR/ios"
# shellcheck disable=SC1091
set -a; source .asc.env; set +a
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "ERROR: ASC key not found: $KEY_PATH" >&2; exit 1; }

echo "==> [3/7] Unlock signing keychain"
security unlock-keychain -p "$(cat "$KC_PW_FILE")" "$KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$SIGN_IDENTITY" \
  || { echo "ERROR: '$SIGN_IDENTITY' not in $KEYCHAIN — re-run .temp/asc_mkcert.py" >&2; exit 1; }

echo "==> [4/7] Stage web bundle + disk image (clean, sqrlbot-owned)"
./stage.sh

echo "==> [5/7] Generate project + stamp unique build number"
xcodegen generate
BUILD_NUM="$(date +%s)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" App/Info.plist
echo "    CFBundleVersion=$BUILD_NUM"

echo "==> [6/7] Archive (Release, MANUAL signing with sqrlbot's identity)"
ARCHIVE="$BUILD_DIR/ios/.build-xcode/WebVM.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project WebVM.xcodeproj -scheme "$SCHEME" -sdk iphoneos -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$SIGN_PROFILE" DEVELOPMENT_TEAM="$ASC_TEAM_ID" \
  archive

echo "==> [7/7] Export + upload to TestFlight (.p8 auth)"
EXPORT_DIR="$BUILD_DIR/ios/.build-xcode/export"
EXPORT_OPTS="$BUILD_DIR/ios/.build-xcode/ExportOptions.plist"
rm -rf "$EXPORT_DIR"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${ASC_TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGN_IDENTITY}</string>
  <key>provisioningProfiles</key><dict>
    <key>${BUNDLE_ID}</key><string>${SIGN_PROFILE}</string>
  </dict>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF
# /usr/bin first so Xcode uses system rsync (a Homebrew rsync breaks -exportArchive).
PATH=/usr/bin:$PATH xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTS" \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> DONE: sqrlbot uploaded build $BUILD_NUM to TestFlight (bundle $BUNDLE_ID)"
