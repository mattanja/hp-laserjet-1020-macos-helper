#!/bin/sh
# Advertise the shared HP LaserJet 1020 as IPP + AirPrint + Mopria.
#
# macOS CUPS also publishes _ipps._tcp with TLS=1.2, but its certificate
# is self-signed for the Mac's router hostname, not *.local. Android HP Print
# Service and Mopria then fail the TLS handshake. Install turns off CUPS's
# own Bonjour ads; this process registers plaintext IPP with the TXT keys
# those clients require (mopria-certified, URF, image/urf).
set -eu

QUEUE_NAME="HP_LaserJet_1020"
SERVICE_NAME="HP LaserJet 1020"
PORT=631
UUID="3027255a-8239-3ed3-69ec-6fa2644142e6"

exec /usr/bin/dns-sd -R "$SERVICE_NAME" "_ipp._tcp,_universal" local "$PORT" \
  "txtvers=1" \
  "qtotal=1" \
  "rp=printers/${QUEUE_NAME}" \
  "ty=HP LaserJet 1020" \
  "product=(HP LaserJet 1020)" \
  "note=USB" \
  "priority=0" \
  "pdl=application/pdf,image/pwg-raster,image/urf,image/jpeg" \
  "mopria-certified=1.3" \
  "URF=W8,SRGB24,RS600,DM1,IS1" \
  "Color=F" \
  "Duplex=F" \
  "uuid=${UUID}"
