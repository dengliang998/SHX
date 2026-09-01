#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-release}"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Packaging/Info.plist")
if [[ ! -f "$ROOT_DIR/Packaging/SHX.icns" ]]; then
    "$ROOT_DIR/Scripts/build-icon.sh"
fi
swift build -c "$CONFIGURATION" --arch arm64

BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/SHX.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
for stale_icon in "$APP_DIR/Contents/Resources"/SHX*.icns(N); do
    unlink "$stale_icon"
done
install -m 755 "$BIN_DIR/SHX" "$APP_DIR/Contents/MacOS/SHX"
install -m 755 "$BIN_DIR/SHXUpdater" "$APP_DIR/Contents/Resources/SHXUpdater"
install -m 644 "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$ROOT_DIR/Packaging/SHX.icns" "$APP_DIR/Contents/Resources/SHX-$APP_VERSION.icns"
install -m 755 "$ROOT_DIR/Packaging/SHXAskPass" "$APP_DIR/Contents/Resources/SHXAskPass"
install -m 644 "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 "$ROOT_DIR/CHANGELOG.md" "$APP_DIR/Contents/Resources/CHANGELOG.md"
install -m 644 "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"

for localization in "$ROOT_DIR/Resources"/*.lproj(N); do
    ditto "$localization" "$APP_DIR/Contents/Resources/${localization:t}"
done

for resource_bundle in "$BIN_DIR"/*.bundle(N); do
    ditto "$resource_bundle" "$APP_DIR/Contents/Resources/${resource_bundle:t}"
done

SIGNING_IDENTITY="${SHX_SIGNING_IDENTITY:-SHX Local Code Signing}"
if security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
    codesign \
        --force \
        --deep \
        --timestamp=none \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
else
    print -u2 "warning: '$SIGNING_IDENTITY' is unavailable; falling back to ad-hoc signing"
    codesign \
        --force \
        --deep \
        --sign - \
        --requirements '=designated => identifier "com.shx.app"' \
        "$APP_DIR"
fi
echo "$APP_DIR"
