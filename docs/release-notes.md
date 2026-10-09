FastScan now installs on any Mac with Apple silicon: put a stack in the feeder, press Scan, and it's filed where it belongs.

## What's new

- No Homebrew. FastScan carries its own copy of SANE, the driver that talks to the scanner, so there is nothing else to install.
- Signed with a Developer ID and notarized by Apple. macOS opens FastScan like any other downloaded app, without a trip to Privacy & Security.
- **FastScan › Acknowledgements** lists the open-source software inside the app and its licenses.

## What it does

- Scans papers and photos from an Epson FastFoto FF-680W over Wi-Fi, both sides, and drops blank backs.
- Turns papers into searchable PDFs, about 1 MB per page or less.
- Suggests a name and folder for each document with Apple's on-device model, following the patterns already in your filing cabinet. Nothing is filed until you press File It, and Undo puts it back.
- Sends photos to Apple Photos, with writing on the back as the caption.
- Lets you switch a document between color and grayscale, or keep only the fronts, without scanning again.

## Requirements

- A Mac with Apple silicon running macOS 26 or later. Filing suggestions use Apple Intelligence when it is turned on, and a built-in heuristic when it is not.
- An Epson FastFoto FF-680W on the same Wi-Fi network. It is the only scanner tested so far.

If you installed `sane-backends` with Homebrew for FastScan 0.1.0, FastScan no longer uses it. You can keep it or remove it with `brew uninstall sane-backends`.

## Install

1. Download `FastScan-0.2.0.zip` below and unzip it.
2. Move `FastScan.app` to your Applications folder, and open it.
3. When macOS asks whether FastScan may find devices on your local network, choose **Allow**.
4. Open **Settings** (⌘,) and choose your filing cabinet folder. It starts as `~/Documents/Scans`.

To check the download, compare it with `FastScan-0.2.0.zip.sha256`:

```sh
shasum -a 256 -c FastScan-0.2.0.zip.sha256
```

## Source for the bundled SANE

FastScan includes SANE (sane-backends 1.4.0), which is licensed under the GNU General Public License, version 2. `sane-backends-1.4.0.tar.gz` below is its exact source, and `build-sane` is the script that built it.
