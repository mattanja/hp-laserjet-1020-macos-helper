#!/bin/sh
# Standalone HP LaserJet 1020 driver installer for Apple Silicon macOS.

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DRIVER_DIR="$PROJECT_DIR/Driver"
SOURCE_DIR="$DRIVER_DIR/Sources"
FOO2ZJS_DIR="$SOURCE_DIR/foo2zjs"
SOURCE_PPD="$DRIVER_DIR/PPD/HP-LaserJet_1020.ppd"

FILTER_NAME="rastertozjs"
FILTER_DIR="/usr/libexec/cups/filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
FIRMWARE_DIR="/usr/local/share/foo2zjs/firmware"
INSTALLED_PPD="HP-LaserJet_1020-printer-all.ppd"
QUEUE_NAME="HP_LaserJet_1020"
USB_PRODUCT='"USB Product Name" = "HP LaserJet 1020"'
DEFAULT_DEVICE_URI="usb://Hewlett-Packard/HP%20LaserJet%201020"

# Firmware is fetched from an audited, immutable printer-all commit. It is not
# redistributed here because the upstream project identifies it as copyright HP.
FIRMWARE_URL="https://raw.githubusercontent.com/faradayfury/printer-all/b6601e32dd6f8958a2e1422264e53cda938269ee/foo2zjs/sihp1020.img"
FIRMWARE_SHA256="9d10d8e84a9577f268aac6336ed18cf9235e6f732c1f68e8913c787db60106ce"

MODE="install"
STAGE_DIR=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' "Usage: $0 [--stage-only DIRECTORY]"
}

if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = "--stage-only" ]; then
        MODE="stage"
        STAGE_DIR=$2
    else
        usage >&2
        exit 2
    fi
fi

command -v uname >/dev/null 2>&1 || fail "uname is unavailable."
command -v xcrun >/dev/null 2>&1 || fail "Xcode Command Line Tools are required."
command -v curl >/dev/null 2>&1 || fail "curl is unavailable."
command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable."
command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable."
command -v cupstestppd >/dev/null 2>&1 || fail "cupstestppd is unavailable."

[ "$(uname -s)" = "Darwin" ] || fail "This installer supports macOS only."
[ "$(uname -m)" = "arm64" ] || fail "This installer supports Apple Silicon (arm64) only."
[ "$(id -u)" -ne 0 ] || fail "Run this script as your normal user, not with sudo."

if [ "$MODE" = "install" ]; then
    command -v sudo >/dev/null 2>&1 || fail "sudo is unavailable."
    /usr/sbin/ioreg -p IOUSB -l -w0 | /usr/bin/grep -Fq "$USB_PRODUCT" \
        || fail "Switch on and connect the HP LaserJet 1020 over USB, then run setup again."
fi

for required in \
    "$SOURCE_DIR/rastertozjs.c" \
    "$FOO2ZJS_DIR/jbig.c" \
    "$FOO2ZJS_DIR/jbig_ar.c" \
    "$FOO2ZJS_DIR/jbig.h" \
    "$FOO2ZJS_DIR/jbig_ar.h" \
    "$FOO2ZJS_DIR/zjs.h" \
    "$FOO2ZJS_DIR/arm2hpdl.c" \
    "$SOURCE_PPD"
do
    [ -f "$required" ] || fail "Required repository file is missing: $required"
done

CLANG=$(xcrun --find clang) || fail "clang was not found. Install Xcode Command Line Tools."
SDKROOT=$(xcrun --sdk macosx --show-sdk-path) \
    || fail "The macOS SDK was not found. Reinstall Xcode Command Line Tools."
[ -d "$SDKROOT" ] || fail "The reported macOS SDK directory does not exist: $SDKROOT"

BUILD_DIR=$(mktemp -d "${TMPDIR:-/private/tmp}/hp1020-standalone.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

printf '%s\n' "[1/5] Downloading the pinned HP LaserJet 1020 firmware image..."
/usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --silent \
    --show-error \
    --output "$BUILD_DIR/sihp1020.img" \
    "$FIRMWARE_URL"

actual_sha=$(/usr/bin/shasum -a 256 "$BUILD_DIR/sihp1020.img" | /usr/bin/awk '{print $1}')
[ "$actual_sha" = "$FIRMWARE_SHA256" ] \
    || fail "Firmware checksum verification failed; nothing was installed."

printf '%s\n' "[2/5] Building only the LaserJet 1020 raster filter..."
"$CLANG" -o "$BUILD_DIR/$FILTER_NAME" \
    -isysroot "$SDKROOT" \
    "$SOURCE_DIR/rastertozjs.c" \
    "$FOO2ZJS_DIR/jbig.c" "$FOO2ZJS_DIR/jbig_ar.c" \
    -I"$FOO2ZJS_DIR" -lcups -lcupsimage -Wall -O2

/usr/bin/file "$BUILD_DIR/$FILTER_NAME" | /usr/bin/grep -q 'arm64' \
    || fail "The compiled filter is not an arm64 binary."

printf '%s\n' "[3/5] Preparing and validating the firmware and corrected PPD..."
"$CLANG" -o "$BUILD_DIR/arm2hpdl" \
    -isysroot "$SDKROOT" \
    "$FOO2ZJS_DIR/arm2hpdl.c" -I"$FOO2ZJS_DIR" -Wall -O2
"$BUILD_DIR/arm2hpdl" "$BUILD_DIR/sihp1020.img" > "$BUILD_DIR/sihp1020.dl"
[ -s "$BUILD_DIR/sihp1020.dl" ] || fail "Firmware conversion produced an empty file."

cp "$SOURCE_PPD" "$BUILD_DIR/$INSTALLED_PPD"
/usr/bin/grep -Fq '*cupsFilter: "application/vnd.cups-raster 0 rastertozjs"' \
    "$BUILD_DIR/$INSTALLED_PPD" \
    || fail "The bundled PPD does not reference rastertozjs."
/usr/bin/grep -Fq '*Resolution 600x600dpi/600x600 dpi: "<</HWResolution[600 600]>>setpagedevice"' \
    "$BUILD_DIR/$INSTALLED_PPD" \
    || fail "The bundled PPD is missing the macOS resolution fix."
PPD_CHECK_LOG="$BUILD_DIR/cupstestppd.log"
if ! /usr/bin/cupstestppd -W none "$BUILD_DIR/$INSTALLED_PPD" >"$PPD_CHECK_LOG" 2>&1; then
    /bin/cat "$PPD_CHECK_LOG" >&2
    fail "The bundled PPD failed CUPS validation."
fi

/usr/bin/codesign --force --sign - "$BUILD_DIR/$FILTER_NAME"

if [ "$MODE" = "stage" ]; then
    printf '%s\n' "[4/5] Staging the standalone driver artifacts..."
    mkdir -p \
        "$STAGE_DIR/usr/libexec/cups/filter" \
        "$STAGE_DIR/Library/Printers/PPDs/Contents/Resources" \
        "$STAGE_DIR/usr/local/share/foo2zjs/firmware"
    cp "$BUILD_DIR/$FILTER_NAME" "$STAGE_DIR/usr/libexec/cups/filter/$FILTER_NAME"
    cp "$BUILD_DIR/$INSTALLED_PPD" "$STAGE_DIR/Library/Printers/PPDs/Contents/Resources/$INSTALLED_PPD"
    cp "$BUILD_DIR/sihp1020.dl" "$STAGE_DIR/usr/local/share/foo2zjs/firmware/sihp1020.dl"
    printf '%s\n' "[5/5] Standalone staging completed without system changes."
    exit 0
fi

printf '%s\n' "[4/5] Installing the three driver files with administrator access..."
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
backup_existing "/etc/cups/ppd/$QUEUE_NAME.ppd" "$QUEUE_NAME-active.ppd"

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

device_uri=$DEFAULT_DEVICE_URI
existing_uri=$(/usr/bin/lpstat -v "$QUEUE_NAME" 2>/dev/null | /usr/bin/sed -n "s/^device for $QUEUE_NAME: //p" | /usr/bin/head -n 1 || true)
if [ -n "$existing_uri" ]; then
    device_uri=$existing_uri
else
    usb_serial=$(/usr/sbin/ioreg -p IOUSB -l -w0 | /usr/bin/awk -F '"' '
        /"USB Product Name" = "HP LaserJet 1020"/ { found = 1; next }
        found && /"USB Serial Number" =/ { print $4; exit }
    ')
    if [ -n "$usb_serial" ]; then
        device_uri="$DEFAULT_DEVICE_URI?serial=$usb_serial"
    fi
fi

sudo /usr/sbin/lpadmin \
    -p "$QUEUE_NAME" \
    -v "$device_uri" \
    -P "$PPD_DIR/$INSTALLED_PPD" \
    -o PageSize=A4 \
    -o Resolution=600x600dpi \
    -E
sudo /usr/sbin/cupsenable "$QUEUE_NAME"
sudo /usr/sbin/cupsaccept "$QUEUE_NAME"

printf '%s\n' "[5/5] Uploading firmware once for the current printer power cycle..."
/usr/bin/lp -d "$QUEUE_NAME" -o raw "$FIRMWARE_DIR/sihp1020.dl" >/dev/null

printf '\n%s\n' "LaserJet 1020 driver, corrected PPD, queue, and firmware are ready."
if [ "$BACKUP_CREATED" -eq 1 ]; then
    printf '%s\n' "Previous files were backed up in: $BACKUP_DIR"
fi
printf '%s\n' "No background task, network service, or macOS security setting was added."
