# Digi Suite 17: Digi Stream engine

Version 1.0.17 (17). Builds on 16 (Drive Check). Other tabs are unchanged.

## Build

```bash
cd "$HOME/Downloads/DigiSuite_Stream_17_1" && bash build.command
```

## What's new

A new copy engine, **Digi Stream**, written from scratch (`DigiStreamEngine.swift`).
It is the default. The v13 engine stays available as **Classic (v13)** in the
menu next to Start Backup, so both can be compared on the same drive without
rebuilding.

How Digi Stream copies:

- **Large files (8 MiB and up)** go one at a time, read in 16 MiB chunks and
  written with the macOS write cache bypassed, into space reserved before
  writing. Aim: a steady stream instead of the cache filling and flushing in
  bursts.
- **Small files** (settings, previews, databases) go four at a time alongside
  the large-file stream.
- Same safety as before: temporary file, source-change check, size check,
  then move into place. Archives, exclusions, empty folders, the manifest and
  the free-space check behave the same.
- **Stop and Pause work mid-file** on large files (Classic waits for the file).
- **Progress counts bytes as they are written**, so the speed graph is accurate.
- After a backup, the destination card shows where the time went, for example
  `Digi Stream · large files: 812, 241 GB at 652 MB/s · small files: 35,888, 15 GB · copy time 410s`.

Backups made by either engine stay incremental with the other (tested both
ways).

## Fixed

- Free space on the destination card did not update after a backup.
  Foundation was returning a cached value.

## How to judge it

Compare on the same drive in the same condition, ideally right after a ditto
run of the same session. Target: within about 10% of ditto. If Classic is
faster on your drive, switch the menu back; that result is useful too.

## Not verified yet

Written on Linux without a Swift compiler. The first compile and the new
engine tests run in build.command on the Mac. No speed claim until measured.

## 17.1

- Link speed now shows for APFS drives. APFS volumes sit on a separate
  synthesized disk, so the drive check now follows the volume to its physical
  disk (via diskutil) before matching it to the USB device.
- First measured result (Nov 1, 2TB T7 freshly erased as APFS, 10 Gb/s):
  Digi Stream copied 256.22 GB / 36,700 files in 6:30, average 657 MB/s.
  Large files 231.54 GB at 597 MB/s; 33,349 small files, 24.69 GB.
