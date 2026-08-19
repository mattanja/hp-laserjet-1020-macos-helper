#!/bin/sh
# Native macOS driver for the USB HP LaserJet 1020 (Apple Silicon).
# Builds rastertozjs + an IOKit CUPS backend that uploads firmware after
# each printer power cycle. Cmd-P from any app. No Raspberry Pi, no Docker.
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$PROJECT_DIR/setup.sh" "$@"
