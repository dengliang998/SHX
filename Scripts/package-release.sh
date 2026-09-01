#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/.build/SHX.app"
INFO_PLIST="$ROOT_DIR/Packaging/Info.plist"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/releases}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
IMAGE_NAME="SHX-$VERSION.dmg"
IMAGE_PATH="$OUTPUT_DIR/$IMAGE_NAME"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/SHX-Release.XXXXXX")

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/Scripts/build-app.sh"
mkdir -p "$OUTPUT_DIR"
ditto "$APP_DIR" "$STAGING_DIR/SHX.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$IMAGE_PATH"
hdiutil create \
    -volname "SHX $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$IMAGE_PATH" >/dev/null

echo "$IMAGE_PATH"
