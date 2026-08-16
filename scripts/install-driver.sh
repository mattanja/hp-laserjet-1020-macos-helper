#!/bin/sh
#
# Narrow installer for the HP LaserJet 1020 on Apple Silicon macOS.
#
# This script deliberately installs only:
#   - rastertozjs (the filter used by the LaserJet 1020)
#   - a corrected LaserJet 1020 PPD that points to rastertozjs
#   - sihp1020.dl (the printer firmware)
#
# Run as your normal user and pass the path to a printer-all checkout:
#   ./scripts/install-driver.sh /path/to/printer-all
#
# The build happens without root privileges. sudo is requested only when the
# three prepared files are copied into their final system locations.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=${1:-${PRINTER_ALL_SOURCE_DIR:-}}
[ -n "$SOURCE_DIR" ] || {
    printf '%s\n' "Usage: $0 /path/to/printer-all" >&2
    exit 2
}
SOURCE_DIR=$(CDPATH= cd -- "$SOURCE_DIR" 2>/dev/null && pwd) \
    || {
        printf 'ERROR: printer-all directory not found: %s\n' "$SOURCE_DIR" >&2
        exit 2
    }
FOO2ZJS_DIR="$SOURCE_DIR/foo2zjs"

FILTER_NAME="rastertozjs"
SOURCE_PPD="$SOURCE_DIR/PPD/HP-LaserJet_1020.ppd"
FIRMWARE_IMAGE="$FOO2ZJS_DIR/sihp1020.img"

FILTER_DIR="/usr/libexec/cups/filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
FIRMWARE_DIR="/usr/local/share/foo2zjs/firmware"
INSTALLED_PPD="HP-LaserJet_1020-printer-all.ppd"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v uname >/dev/null 2>&1 || fail "uname is unavailable."
command -v xcrun >/dev/null 2>&1 || fail "Xcode Command Line Tools are required."
command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable."
command -v sudo >/dev/null 2>&1 || fail "sudo is unavailable."

[ "$(uname -s)" = "Darwin" ] || fail "This installer supports macOS only."
[ "$(uname -m)" = "arm64" ] || fail "This build is intended for Apple Silicon (arm64)."
[ "$(id -u)" -ne 0 ] || fail "Run this script as your normal user, not with sudo."

for required in \
    "$SOURCE_DIR/rastertozjs.c" \
    "$FOO2ZJS_DIR/jbig.c" \
    "$FOO2ZJS_DIR/jbig_ar.c" \
    "$FOO2ZJS_DIR/jbig.h" \
    "$FOO2ZJS_DIR/jbig_ar.h" \
    "$FOO2ZJS_DIR/zjs.h" \
    "$FOO2ZJS_DIR/arm2hpdl.c" \
    "$SOURCE_PPD" \
    "$FIRMWARE_IMAGE"
do
    [ -f "$required" ] || fail "Required source file is missing: $required"
done

CLANG=$(xcrun --find clang) || fail "clang was not found. Install Xcode Command Line Tools."
SDKROOT=$(xcrun --sdk macosx --show-sdk-path) \
    || fail "The macOS SDK was not found. Reinstall Xcode Command Line Tools."
[ -d "$SDKROOT" ] || fail "The reported macOS SDK directory does not exist: $SDKROOT"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/private/tmp}/printer-all-hp1020.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

printf '%s\n' "[1/4] Building the LaserJet 1020 filter without root privileges..."
"$CLANG" -o "$BUILD_DIR/$FILTER_NAME" \
    -isysroot "$SDKROOT" \
    "$SOURCE_DIR/rastertozjs.c" \
    "$FOO2ZJS_DIR/jbig.c" "$FOO2ZJS_DIR/jbig_ar.c" \
    -I"$FOO2ZJS_DIR" -lcups -lcupsimage -Wall -O2

file "$BUILD_DIR/$FILTER_NAME" | grep -q 'arm64' \
    || fail "The compiled filter is not an arm64 binary."

printf '%s\n' "[2/4] Preparing only the LaserJet 1020 firmware..."
"$CLANG" -o "$BUILD_DIR/arm2hpdl" \
    -isysroot "$SDKROOT" \
    "$FOO2ZJS_DIR/arm2hpdl.c" -I"$FOO2ZJS_DIR" -Wall -O2
"$BUILD_DIR/arm2hpdl" "$FIRMWARE_IMAGE" > "$BUILD_DIR/sihp1020.dl"
[ -s "$BUILD_DIR/sihp1020.dl" ] || fail "Firmware conversion produced an empty file."

printf '%s\n' "[3/4] Preparing a PPD that uses the native rastertozjs filter..."
sed \
    -e 's#^\*cupsFilter:.*#*cupsFilter: "application/vnd.cups-raster 0 rastertozjs"#' \
    -e 's#^\*ShortNickName:.*#*ShortNickName: "HP LaserJet 1020 (printer-all native)"#' \
    -e 's#^\*NickName:.*#*NickName: "HP LaserJet 1020 (printer-all native rastertozjs)"#' \
    -e '/^\*FoomaticRIPCommandLine:/d' \
    "$SOURCE_PPD" > "$BUILD_DIR/$INSTALLED_PPD"

grep -Fq '*cupsFilter: "application/vnd.cups-raster 0 rastertozjs"' \
    "$BUILD_DIR/$INSTALLED_PPD" \
    || fail "The prepared PPD does not reference rastertozjs."

printf '%s\n' "[4/4] Ready to install three files. sudo is required for this step."
printf '%s\n' "  $FILTER_DIR/$FILTER_NAME"
printf '%s\n' "  $PPD_DIR/$INSTALLED_PPD"
printf '%s\n' "  $FIRMWARE_DIR/sihp1020.dl"
sudo -v

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="/usr/local/share/printer-all-hp1020/backups/$TIMESTAMP"
BACKUP_CREATED=0

backup_existing() {
    existing=$1
    backup_name=$2
    if [ -e "$existing" ]; then
        if [ "$BACKUP_CREATED" -eq 0 ]; then
            sudo mkdir -p "$BACKUP_DIR"
            BACKUP_CREATED=1
        fi
        sudo cp -p "$existing" "$BACKUP_DIR/$backup_name"
    fi
}

backup_existing "$FILTER_DIR/$FILTER_NAME" "$FILTER_NAME"
backup_existing "$PPD_DIR/$INSTALLED_PPD" "$INSTALLED_PPD"
backup_existing "$FIRMWARE_DIR/sihp1020.dl" "sihp1020.dl"

sudo mkdir -p "$FILTER_DIR" "$PPD_DIR" "$FIRMWARE_DIR"
sudo cp "$BUILD_DIR/$FILTER_NAME" "$FILTER_DIR/$FILTER_NAME"
sudo chown root:wheel "$FILTER_DIR/$FILTER_NAME"
sudo chmod 755 "$FILTER_DIR/$FILTER_NAME"
sudo codesign --force --sign - "$FILTER_DIR/$FILTER_NAME"

sudo cp "$BUILD_DIR/$INSTALLED_PPD" "$PPD_DIR/$INSTALLED_PPD"
sudo chown root:wheel "$PPD_DIR/$INSTALLED_PPD"
sudo chmod 644 "$PPD_DIR/$INSTALLED_PPD"

sudo cp "$BUILD_DIR/sihp1020.dl" "$FIRMWARE_DIR/sihp1020.dl"
sudo chown root:wheel "$FIRMWARE_DIR/sihp1020.dl"
sudo chmod 644 "$FIRMWARE_DIR/sihp1020.dl"

printf '\n%s\n' "Installation finished. CUPS was not restarted automatically."
if [ "$BACKUP_CREATED" -eq 1 ]; then
    printf '%s\n' "Previous files were backed up in: $BACKUP_DIR"
fi
printf '%s\n' "Next: add the printer in System Settings and select:"
printf '%s\n' "  HP LaserJet 1020 (printer-all native rastertozjs)"
printf '%s\n' "The firmware file is installed but has not been sent to the printer."
printf '%s\n' "No security settings were changed."
