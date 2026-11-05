# Digi Suite 18: Backups tab rework, Digi Stream only

Version 1.0.18. Other tabs are unchanged.

```bash
cd "$HOME/Downloads/DigiSuite_18_4" && bash build.command
```

## Engine
- The Classic (v13) copy engine is removed. Every backup uses Digi Stream.
- The original backup safety tests (exclusions, hidden files, symlinks,
  source changes, missing destinations, archives, stop/pause, adoption of
  existing copies) now run against Digi Stream.

## Backups tab
- Slim control bar at the top: Start Backup / Trial Sync, or Pause All,
  Resume All and Stop All while running, plus one summary line
  (transferred, files, average and current speed, ETA).
- Source is a single slim row.
- One large card per destination, side by side when the window is wide
  enough, stacked when narrow. Each card is titled with the drive name
  (for example WolkPhoto2TB), with the folder path underneath.
- Per-drive Pause / Resume and Stop are labeled buttons. A paused drive's
  progress bar and status turn orange.
- Taller speed graph per drive.
- "Last backup" line on each card, kept across launches (date, files,
  size, time, average speed).
- Eject button on each external drive when no backup is running.
- Timing breakdown and engine line hidden behind "Details".
- "Speed Benchmark…" removed (it measured the old engine).
- "Connected Drives" replaces Discover Drives / Add Matching Session /
  Create Session Folder: each drive has one "Use This Drive" button (it
  creates the session folder if needed, after a confirmation), and drives in
  use show "In use" with "Stop Using" (nothing on the drive is deleted).
  Drives are listed automatically when the tab opens.
- A disconnected destination shows "Not connected".

## Workspace auto-save
- Changes to destinations, exclusions and archive options, and each finished
  backup, save the workspace automatically. If no workspace file is open,
  one is created at ~/Documents/DigiSuite/<session>.digitools (an existing
  file there is never overwritten).

## Not verified yet
Written without a Swift compiler; first compile happens in build.command.

## 18.1
- Up to four drives copy at the same time (was two). A fifth or later drive
  shows "Queued: starts when another drive finishes" and starts automatically.
- The overall ETA ignores drives that are queued or still starting, so it no
  longer stays on "Calculating…".

## 18.2
- Refresh the drive list any time, including during a backup.
- "Use This Drive" or "Add Folder…" during a backup adds the drive and starts
  copying to it immediately (its own card, graph, Pause and Stop). If the
  backup is paused, the new drive waits with the others until Resume All.
- The backup finishes once every drive, including ones added mid-run, is done.
- "Stop Using" and the card's remove button work for idle drives during a
  backup; a drive that is copying must be stopped from its card first.

## 18.3
- Pausing shows "Pausing… finishing the current file" only while a copy is
  still writing, then a calm "Paused" once nothing is being written.
- While paused: "Now" reads 0 MB/s, ETA reads "Paused", and the graph shows
  the pause as a flat stretch. The top header and menu bar say "Paused" once
  every drive has stopped writing.
- Average speed and ETA leave out time spent paused.

## 18.4
- When every running drive is paused (by Pause All or one at a time), the top
  shows Resume All, the header says Paused and the ETA reads Paused. Resume
  All restarts every drive.
- With only some drives paused, the top keeps Pause All and the header reads
  "Backing up · N paused". Menu bar and keyboard shortcut follow the same rule.
