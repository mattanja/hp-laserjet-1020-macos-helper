#!/bin/sh
# One-command setup for the HP LaserJet 1020 macOS helper.

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE="install"
STAGE_DIR=""

if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = "--stage-only" ]; then
        MODE="stage"
        STAGE_DIR=$2
    else
        printf '%s\n' "Usage: $0 [--stage-only DIRECTORY]" >&2
        exit 2
    fi
fi

if ! command -v xcrun >/dev/null 2>&1; then
    printf '%s\n' "Xcode Command Line Tools are required."
    printf '%s\n' "Run: xcode-select --install"
    printf '%s\n' "After installation finishes, run this setup again."
    exit 1
fi

if [ "$MODE" = "stage" ]; then
    mkdir -p "$STAGE_DIR"
    "$PROJECT_DIR/scripts/install-driver.sh" --stage-only "$STAGE_DIR/driver-root"
    BUILD_ROOT="$STAGE_DIR/app-build" "$PROJECT_DIR/scripts/build-app.sh"
    mkdir -p "$STAGE_DIR/Desktop"
    /usr/bin/ditto \
        "$STAGE_DIR/app-build/Prepare HP LaserJet.app" \
        "$STAGE_DIR/Desktop/Prepare HP LaserJet.app"
    printf '\n%s\n' "Standalone staging test completed without modifying the Mac."
    exit 0
fi

"$PROJECT_DIR/scripts/install-driver.sh"
"$PROJECT_DIR/scripts/build-app.sh"

DESKTOP_APP="$HOME/Desktop/Prepare HP LaserJet.app"
BUILT_APP="$PROJECT_DIR/build/Prepare HP LaserJet.app"

if [ -e "$DESKTOP_APP" ]; then
    BACKUP_ROOT="$HOME/Library/Application Support/Prepare HP LaserJet/backups"
    BACKUP_APP="$BACKUP_ROOT/Prepare HP LaserJet-$(date '+%Y%m%d-%H%M%S').app"
    mkdir -p "$BACKUP_ROOT"
    /usr/bin/ditto "$DESKTOP_APP" "$BACKUP_APP"
fi

/usr/bin/ditto "$BUILT_APP" "$DESKTOP_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DESKTOP_APP"
"$DESKTOP_APP/Contents/MacOS/PrepareHPLaserJet" --self-test

printf '\n%s\n' "Complete setup finished."
printf '%s\n' "Print from any app with Cmd-P to HP LaserJet 1020."
printf '%s\n' "Firmware uploads automatically after a power cycle."
printf '%s\n' "Optional fallback on the Desktop: Prepare HP LaserJet.app"

