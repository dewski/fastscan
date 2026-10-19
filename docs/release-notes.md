A fix for a crash while scanning.

## What's new

- FastScan no longer crashes when a page is an even gray all the way to its edge, such as the plain back of a photo. Pages like this are now kept at their full scanned size.

Coming from 0.3.0? Version 0.3.1 explained scanner problems in plain language, went back to the ready screen when you stop a scan before any page comes through, and lined up the labels in Settings.

## What it does

- Scans papers and photos from an Epson FastFoto FF-680W over Wi-Fi, both sides, and drops blank backs.
- Turns papers into searchable PDFs, about 1 MB per page or less.
- Suggests a name and folder for each document with Apple's on-device model, following the patterns already in your filing cabinet. Nothing is filed until you press File It, and Undo puts it back.
- Sends photos to Apple Photos, with writing on the back as the caption.
- Lets you switch a document between color and grayscale, or keep only the fronts, without scanning again.

## Requirements

- A Mac with Apple silicon running macOS 26 or later. Filing suggestions use Apple Intelligence when it is turned on, and a built-in heuristic when it is not.
- An Epson FastFoto FF-680W on the same Wi-Fi network. It is the only scanner tested so far.

## Install

1. Download `FastScan-0.3.2.zip` below and unzip it.
2. Move `FastScan.app` to your Applications folder, and open it.
3. When macOS asks whether FastScan may find devices on your local network, choose **Allow**.
4. Open **Settings** (⌘,) and choose your filing cabinet folder. It starts as `~/Documents/Scans`.

To check the download, compare it with `FastScan-0.3.2.zip.sha256`:

```sh
shasum -a 256 -c FastScan-0.3.2.zip.sha256
```
