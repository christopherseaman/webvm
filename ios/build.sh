#!/bin/bash
# Feasibility-spike build: stage web bundle -> generate Xcode project ->
# build for the iOS Simulator -> install + launch on the booted simulator.
# Logs from subsystem app.ish.iSH.KTGSS9PB3A carry the crossOriginIsolated + boot trace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUNDLE_ID="app.ish.iSH.KTGSS9PB3A"
SCHEME="WebVM"
DERIVED="$SCRIPT_DIR/.build-xcode"
SIM_NAME_DEFAULT="iPad Pro 11-inch (M5)"

echo "==> [1/5] Stage web bundle + disk image"
"$SCRIPT_DIR/stage.sh"

echo "==> [2/5] Generate Xcode project (xcodegen)"
xcodegen generate

echo "==> [3/5] Resolve booted simulator"
UDID="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}' | head -1 || true)"
if [[ -z "${UDID:-}" ]]; then
  echo "    no booted simulator; booting '$SIM_NAME_DEFAULT'"
  UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME_DEFAULT (" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}' | head -1)"
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b
fi
echo "    UDID=$UDID"

echo "==> [4/5] Build for iOS Simulator (Debug, unsigned)"
xcodebuild \
  -project WebVM.xcodeproj \
  -scheme "$SCHEME" \
  -sdk iphonesimulator \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED/Build/Products/Debug-iphonesimulator/WebVM.app"
if [[ ! -d "$APP" ]]; then echo "ERROR: app not found at $APP" >&2; exit 1; fi

echo "==> [5/5] Install + launch on $UDID"
xcrun simctl install "$UDID" "$APP"
open -a Simulator || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo "==> Launched $BUNDLE_ID. Capture the boot trace with:"
echo "    xcrun simctl spawn $UDID log show --style compact --last 2m --predicate 'subsystem == \"app.ish.iSH.KTGSS9PB3A\"'"
