#!/bin/bash
# Build the WebVM web bundle in iOS mode and stage it (plus the disk image)
# into ios/web/webroot/, the folder reference shipped in the app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WEBROOT="$SCRIPT_DIR/web/webroot"
IMG="$REPO_ROOT/custom-disk-images/debian_mini.ext2"

if [[ ! -f "$IMG" ]]; then
  echo "ERROR: disk image not found at $IMG" >&2
  echo "Download it: curl -L -o '$IMG' https://github.com/leaningtech/webvm/releases/download/ext2_image/debian_mini_20230519_5022088024.ext2" >&2
  exit 1
fi

echo "==> Building WebVM web bundle (WEBVM_MODE=ios)"
( cd "$REPO_ROOT" && WEBVM_MODE=ios npm run build )

echo "==> Staging webroot"
rm -rf "$WEBROOT"
mkdir -p "$WEBROOT/disk"
cp -R "$REPO_ROOT/build/." "$WEBROOT/"

echo "==> Placing disk image (APFS clone if possible)"
cp -c "$IMG" "$WEBROOT/disk/debian_mini.ext2" 2>/dev/null || cp "$IMG" "$WEBROOT/disk/debian_mini.ext2"

echo "==> Staged: $(du -sh "$WEBROOT" | cut -f1) at $WEBROOT"
ls "$WEBROOT/index.html" "$WEBROOT/disk/debian_mini.ext2" >/dev/null && echo "==> OK: index.html + disk image present"
