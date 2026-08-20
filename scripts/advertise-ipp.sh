#!/bin/sh
# Advertise the shared HP LaserJet 1020 as IPP + AirPrint + Mopria.
#
# macOS CUPS also publishes _ipps._tcp with TLS=1.2, but its certificate
# is self-signed for the Mac's router hostname, not *.local. Android HP Print
# Service and Mopria then fail the TLS handshake. Install turns off CUPS's
# own Bonjour ads; this process registers plaintext IPP with the TXT keys
# AirPrint and Mopria require.
#
# iOS shows a printer under "Other Printers" then deselects it if the TXT
# record is incomplete or inconsistent (e.g. lowercase uuid=, Color=F with
# SRGB24). Keys and values below follow working AirPrint mono printers and
# CUPS's own dnssdBuildTxtRecord().
set -eu

QUEUE_NAME="HP_LaserJet_1020"
SERVICE_NAME="HP LaserJet 1020"
PORT=631
UUID="3027255a-8239-3ed3-69ec-6fa2644142e6"
HOST="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || hostname -s)"
ADMINURL="http://${HOST}.local.:${PORT}/printers/${QUEUE_NAME}"

exec /usr/bin/dns-sd -R "$SERVICE_NAME" "_ipp._tcp,_universal" local. "$PORT" \
  "txtvers=1" \
  "qtotal=1" \
  "rp=printers/${QUEUE_NAME}" \
  "ty=HP LaserJet 1020" \
  "product=(HP LaserJet 1020)" \
  "note=USB" \
  "priority=0" \
  "adminurl=${ADMINURL}" \
  "pdl=application/pdf,image/jpeg,image/pwg-raster,image/urf" \
  "URF=V1.4,W8,CP1,RS600,DM1,IS1" \
  "Color=F" \
  "Duplex=F" \
  "Copies=T" \
  "Collate=T" \
  "Scan=F" \
  "Fax=F" \
  "UUID=${UUID}" \
  "kind=document" \
  "PaperMax=legal-A4" \
  "mopria-certified=1.3" \
  "printer-state=3" \
  "printer-type=0x8096"
