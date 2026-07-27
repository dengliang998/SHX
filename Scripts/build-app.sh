#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-release}"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/KiteShell.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
for stale_icon in "$APP_DIR/Contents/Resources"/KiteShell*.icns(N); do
    unlink "$stale_icon"
done
install -m 755 "$BIN_DIR/KiteShell" "$APP_DIR/Contents/MacOS/KiteShell"
install -m 644 "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$ROOT_DIR/Packaging/KiteShell.icns" "$APP_DIR/Contents/Resources/KiteShell-0.5.3.icns"
install -m 755 "$ROOT_DIR/Packaging/KiteShellAskPass" "$APP_DIR/Contents/Resources/KiteShellAskPass"
install -m 644 "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 "$ROOT_DIR/CHANGELOG.md" "$APP_DIR/Contents/Resources/CHANGELOG.md"

for resource_bundle in "$BIN_DIR"/*.bundle(N); do
    ditto "$resource_bundle" "$APP_DIR/Contents/Resources/${resource_bundle:t}"
done

SIGNING_IDENTITY="${KITESHELL_SIGNING_IDENTITY:-KiteShell Local Code Signing}"
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
        --requirements '=designated => identifier "com.kiteshell.app"' \
        "$APP_DIR"
fi
echo "$APP_DIR"
