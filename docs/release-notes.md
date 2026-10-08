The first release of FastScan: put a stack in the feeder, press Scan, and it's filed where it belongs.

## What it does

- Scans papers and photos from an Epson FastFoto FF-680W over Wi-Fi, both sides, and drops blank backs.
- Turns papers into searchable PDFs, about 1 MB per page or less.
- Suggests a name and folder for each document with Apple's on-device model, following the patterns already in your filing cabinet. Nothing is filed until you press File It, and Undo puts it back.
- Sends photos to Apple Photos, with writing on the back as the caption.
- Lets you switch a document between color and grayscale, or keep only the fronts, without scanning again.

## Requirements

- A Mac with Apple silicon running macOS 26 or later. Filing suggestions use Apple Intelligence when it is turned on, and a built-in heuristic when it is not.
- An Epson FastFoto FF-680W on the same Wi-Fi network. It is the only scanner tested so far.
- Homebrew's SANE package, which FastScan uses to talk to the scanner:

  ```sh
  brew install sane-backends
  ```

## Install

1. Download `FastScan-0.1.0.zip` below and unzip it.
2. Move `FastScan.app` to your Applications folder.
3. This build is not notarized by Apple, so macOS blocks the first launch. Open FastScan once, then go to **System Settings › Privacy & Security** and click **Open Anyway**. Or run this in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/FastScan.app
   ```

4. When macOS asks whether FastScan may find devices on your local network, choose **Allow**.
5. Open **Settings** (⌘,) and choose your filing cabinet folder. It starts as `~/Documents/Scans`.

To check the download, compare it with `FastScan-0.1.0.zip.sha256`:

```sh
shasum -a 256 -c FastScan-0.1.0.zip.sha256
```
