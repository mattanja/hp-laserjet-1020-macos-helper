#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="Prepare HP LaserJet.app"
BUILD_ROOT=${BUILD_ROOT:-"$PROJECT_DIR/build"}
APP_DIR="$BUILD_ROOT/$APP_NAME"
MACOS_DIR="$APP_DIR/Contents/MacOS"

command -v xcrun >/dev/null 2>&1 || {
    printf '%s\n' "ERROR: Xcode Command Line Tools are required." >&2
    exit 1
}

SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

xcrun clang \
    -fobjc-arc \
    -O2 \
    -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" \
    -framework Cocoa \
    -o "$MACOS_DIR/PrepareHPLaserJet" \
    "$PROJECT_DIR/Sources/PrepareHPLaserJet.m"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
