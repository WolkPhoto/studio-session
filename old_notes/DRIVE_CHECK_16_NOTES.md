# Digi Suite 16: Drive Check

Version 1.0.16 (16), built from the original v13 source (Continuous Copy 13).
Nothing from v14, v14.1, v15 or v15.1 is included.

## Build

Extract the ZIP into Downloads, then in Terminal:

```bash
cd "$HOME/Downloads/DigiSuite_Drive_Check_16" && bash build.command
```

The build runs the backup tests first, then compiles, signs and opens the app.
If a test or the compile fails, copy the error text from Terminal.

Before switching versions: stop any running backup, wait for it to finish
stopping, then quit the old Digi Suite. After launch, you can confirm which
copy is running with:

```bash
pgrep -fl "Digi Suite.app/Contents/MacOS/Digi Suite"
```

The path should include `DigiSuite_Drive_Check_16`.

## Why this version exists

On November 1 the same 256.22 GB session took 10:31 with Digi v13 and 10:14
with Carbon Copy Cloner on the 2TB, and 6:47 (Digi v12) versus 6:53 (CCC) on
the 4TB. Digi's copy engine is already performing at the level of a mature
commercial tool. The faster ditto runs were the first copies of the day, and
every later run was slower on both drives regardless of app.

Evidence points at the drives and their connection, not the copy code:

- The T7 has been caught connecting at 480 Mb/s (USB 2) on one port.
- The Oct 31 disk monitor shows one drive flat between 400 and 450 MB/s
  across about half an hour of runs, the usual ceiling of a 5 Gb/s link.
- The 4TB reached 100% full (28 GB free) during testing. SSDs write much
  more slowly when nearly full, matching Mirror's 40 MB/s dips.

These are strong suspects, not proven causes. v16 makes them visible on every
backup instead of tuning the copy engine further.

## What changed

### Copy engine: unchanged behavior

Still two files at a time per destination, up to two destinations at once,
staged temp files, source-change checks, archives, exclusions, empty folders,
manifest format and Pause/Stop at file boundaries. No speculative tuning.

### Drive connection and space check (new `DriveCheck.swift`)

- Each destination card shows the USB link speed macOS negotiated
  (for example `USB 10 Gb/s`), free space, total size and format.
- Orange warnings appear when a link is below 10 Gb/s or a drive has less
  than 10% free.
- **Start Backup** checks connections first (about 1 to 3 seconds). If a
  drive is below 10 Gb/s, Digi asks before copying: **Back Up Anyway** or
  **Cancel**. Scheduled backups never wait on this prompt.
- Link speed comes from `system_profiler SPUSBDataType`, read only.
  Thunderbolt, internal and network drives show "Link speed not reported".

### Free-space check before copying (engine)

If the new and changed files cannot fit on a destination, that destination
stops before copying anything, with a clear message:
`Not enough space on this drive: this backup needs X but only Y is free.`
Archived files stay on the drive, so they count toward the space needed.
Up-to-date incrementals are never blocked by this check.

### Progress screen

- Per destination: **Now**, **Avg** and **Peak** speed, a speed graph for
  the whole run (dips and recovery stay visible), and transferred / total /
  remaining bytes.
- Per destination **Pause/Resume** and **Stop** buttons while that
  destination is copying. Stopping one destination lets the others, including
  any queued third destination, keep going.
- Top-level buttons are now **Pause All / Resume All / Stop All**. Resume All
  also resumes any destination paused individually.
- Overall progress shows a live **Now** speed next to the average.
- Error messages are shown in full and can be selected and copied.
- The finished summary counts stopped destinations separately.

"Now" is the last 3 seconds. Speeds are logical copy speed (bytes committed
over time), like Mirror and CCC show, not raw disk throughput. Early numbers
can read high while macOS caches writes in memory.

## Tests added (run by build.command)

- Per-destination stop leaves other destinations running; parent pause and
  stop reach every destination.
- Free-space check refuses a backup that cannot fit, allows unknown free
  space, and never blocks an up-to-date incremental.
- Speed history folding.
- USB report parsing using Jeff's real Terminal output from November 1, plus
  a fuller device tree with a hub and a USB 2 fallback; warning thresholds.

## Not verified yet

This version was written on a Linux machine with no Swift compiler or macOS
SDK. Checks done there: delimiter/string balance of every Swift file, the USB
parser logic simulated against both test fixtures, and a line-by-line review
of the diff against v13. The first real compile and test run happens when
`build.command` runs on the Mac. No speed improvement is claimed for this
version.

## Still pending

- Optional `_original` backups for Metadata Watcher (requested earlier).
- Swift 6 / deprecation warnings carried over from v13.
