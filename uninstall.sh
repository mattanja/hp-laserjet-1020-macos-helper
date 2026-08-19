#!/bin/sh
# Remove everything install.sh / setup.sh set up.
set -u

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Removing printer queue..."
lpadmin -x HP_LaserJet_1020 2>/dev/null || true

say "Removing native filter, IOKit backend, PPD, and firmware (needs sudo)..."
sudo rm -f \
    /usr/libexec/cups/filter/rastertozjs \
    /usr/libexec/cups/backend/hp1020x \
    /Library/Printers/PPDs/Contents/Resources/HP-LaserJet_1020-printer-all.ppd \
    /usr/local/share/foo2zjs/firmware/sihp1020.dl \
    /usr/local/share/foo2zjs/firmware/.usb-session
sudo rm -rf /Library/Printers/hp/laserjet/hp1020

DESKTOP_APP="$HOME/Desktop/Prepare HP LaserJet.app"
if [ -e "$DESKTOP_APP" ]; then
    say "Removing Desktop helper app..."
    rm -rf "$DESKTOP_APP"
fi

echo
echo "Done. Optional leftovers: $HOME/Library/Application Support/Prepare HP LaserJet"
echo "and /usr/local/share/printer-all-hp1020/backups (previous-file backups)."
