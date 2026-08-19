# Third-party notices

## printer-all

- Project: <https://github.com/faradayfury/printer-all>
- Audited source commit: `b6601e32dd6f8958a2e1422264e53cda938269ee`
- Purpose: ARM64 macOS CUPS filters, PPDs, firmware preparation, and color profiles
- License: GNU General Public License version 2 or later

This repository vendors only the source files needed for the HP LaserJet 1020 path: `rastertozjs.c`, required JBIG files and headers, `zjs.h`, `arm2hpdl.c`, and the LaserJet 1020 PPD. The PPD contains a documented macOS resolution correction.

Copyright and license notices in the vendored source remain intact. The applicable GPL text is in `LICENSES/GPL-2.0-or-later.txt`.

## foo2zjs

- Original author: Rick Richardson
- Purpose: Open-source printer drivers and firmware-loading workflow for ZjStream-family printers
- License: GNU General Public License version 2 or later

`printer-all` documents its filters as rewrites based on `foo2zjs`.

## hp-laser-1008a-macos

- Project: <https://github.com/Kuberwastaken/hp-laser-1008a-macos>
- Purpose: Native IOKit CUPS USB backend pattern (root Seize, classic printer-class alt setting)
- License: MIT

`backend/hp1020x.c` is adapted from that project's `daemon/hpl1008-usbd.c`. It matches only HP LaserJet 1020 (`0x03F0:0x2B17`) and adds firmware upload after USB reconnect.

## HP firmware

Firmware images used by the upstream project are copyright HP. This repository does not include or redistribute those images.

At setup time, the script retrieves only the required `sihp1020.img` file from the immutable audited upstream commit over HTTPS and verifies its pinned SHA-256 checksum before processing it locally.
