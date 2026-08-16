# HP LaserJet 1020 macOS Helper

A standalone, one-command setup for using the USB-only HP LaserJet 1020 on modern Apple Silicon Macs, plus a one-click firmware loader for later printer power cycles.

The LaserJet 1020 stores its operating firmware in volatile memory. After the printer loses power, the firmware must be uploaded again before normal print jobs can run. This project installs the minimal native driver, corrected printer definition, CUPS queue, firmware, and Desktop helper without requiring a separate driver repository or manual PPD editing.

## Quick setup on a new Mac

1. Switch on the HP LaserJet 1020 and connect it over USB.
2. Install Apple's Xcode Command Line Tools if they are not already present:

   ```bash
   xcode-select --install
   ```

3. Clone this repository and run setup:

   ```bash
   git clone https://github.com/sksonip/hp-laserjet-1020-macos-helper.git
   cd hp-laserjet-1020-macos-helper
   ./setup.sh
   ```

The script requests the Mac administrator password only when installing the three system driver files and configuring the printer queue.

After setup, **Prepare HP LaserJet.app** appears on the Desktop. Open it once after each printer power cycle, wait for **Printer ready**, and then print normally from Word, Preview, Chrome, or any other application.

## What setup does

- Verifies macOS, Apple Silicon, required source files, and build tools
- Downloads only the HP LaserJet 1020 firmware image from an immutable upstream commit
- Verifies the firmware with a pinned SHA-256 checksum before using it
- Builds only the native ARM64 `rastertozjs` filter
- Generates the printer firmware locally
- Validates and installs the corrected LaserJet 1020 PPD
- Creates or repairs the `HP_LaserJet_1020` USB CUPS queue
- Sets A4 and true 600×600 dpi as the defaults
- Builds and ad-hoc signs the native Desktop helper
- Uploads firmware once for the current printer power cycle
- Backs up any driver or queue files it replaces

It does not install drivers for the other 88 printer models in the upstream project.

## What is stored in this repository

The repository includes the minimum source needed to reproduce the working setup:

```text
Driver/
  PPD/HP-LaserJet_1020.ppd       Final corrected PPD
  Sources/rastertozjs.c          Native CUPS raster filter
  Sources/foo2zjs/               Required JBIG and firmware-conversion sources
Sources/PrepareHPLaserJet.m      Native one-click macOS helper
Resources/Info.plist             App metadata
scripts/build-app.sh             Reproducible app build
scripts/install-driver.sh        Standalone driver and queue installer
setup.sh                         Complete setup entry point
```

No separate `printer-all` clone is required.

## Firmware handling

HP firmware is not committed to this repository. During setup, the installer downloads only `sihp1020.img` from audited upstream commit `b6601e32dd6f8958a2e1422264e53cda938269ee` and requires this SHA-256 checksum:

```text
9d10d8e84a9577f268aac6336ed18cf9235e6f732c1f68e8913c787db60106ce
```

If the download changes or is corrupted, setup stops before requesting administrator access or installing anything.

## Resolution correction

The legacy Foomatic PPD encoded its resolution choices as comments that modern macOS did not interpret. `cgpdftoraster` silently fell back to 100 dpi, while the printer filter labeled the bitmap as 600 dpi. The result was an entire page printed at roughly one-sixth size near the top center.

The bundled corrected PPD contains real `HWResolution` instructions and defaults to 600×600 dpi. On A4, CUPS now produces approximately 4769×6828 pixels instead of the faulty 795×1138 pixels.

## One-click helper

The Desktop app:

- Confirms the exact HP LaserJet 1020 USB device is connected
- Confirms the `HP_LaserJet_1020` CUPS queue exists
- Confirms the installed firmware file is readable
- Uploads the firmware as one raw CUPS job
- Exits after reporting success or failure

It creates no polling process, login item, daemon, telemetry, or background task.

## Safe staging test

Maintainers can test the complete standalone build without changing the Mac:

```bash
./setup.sh --stage-only /private/tmp/hp1020-stage
```

This downloads and verifies the firmware, builds the filter and app, validates the PPD, and stages the expected installation tree without using `sudo` or changing CUPS.

## Tested configuration

- MacBook Air with Apple Silicon (M3)
- macOS 26.5.2
- HP LaserJet 1020 connected over USB
- Native ARM64 `rastertozjs` filter
- Microsoft Word documents and the physical CUPS test page at normal A4 scale

## Privacy and security

- No document access
- No telemetry
- No persistent network service
- No background process or startup item
- Fixed printer queue and firmware paths
- HTTPS-only firmware download from a pinned commit
- Mandatory SHA-256 verification
- Compilation before administrator access
- Backups before system-file replacement

## Attribution and licenses

The native app and original setup code are licensed under MIT; see [`LICENSES/MIT.txt`](LICENSES/MIT.txt).

The vendored printer filter, PPD, JBIG support, and firmware-conversion source are derived from [`faradayfury/printer-all`](https://github.com/faradayfury/printer-all) and Rick Richardson's `foo2zjs`, under GPL-2.0-or-later; see [`LICENSES/GPL-2.0-or-later.txt`](LICENSES/GPL-2.0-or-later.txt) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

HP firmware remains copyright HP and is not redistributed in this repository.
