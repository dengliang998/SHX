#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build/self-tests"
mkdir -p "$BUILD_DIR"

/usr/bin/swiftc \
    -swift-version 6 \
    -parse-as-library \
    -framework LocalAuthentication \
    -framework Security \
    "$ROOT_DIR/Sources/RemoteHub/AppLanguage.swift" \
    "$ROOT_DIR/Sources/RemoteHub/Models.swift" \
    "$ROOT_DIR/Sources/RemoteHub/RemoteServices.swift" \
    "$ROOT_DIR/Sources/RemoteHub/LocalCredentialVault.swift" \
    "$ROOT_DIR/Sources/RemoteHub/OneTimePasswordBroker.swift" \
    "$ROOT_DIR/Scripts/self-test.swift" \
    -o "$BUILD_DIR/KiteShellSelfTests"

"$BUILD_DIR/KiteShellSelfTests" "$@"
