# Digi Suite 11: Fast incremental backups

Normal manual and scheduled backups now copy new and changed files without
calculating source or destination SHA-256 hashes. This implements Jeff's
November 1 decision: ordinary copies are sufficient for routine backups, with
Folder Compare > Deep Verify available when a content check is wanted.

## Build and launch

Extract the ZIP into Downloads, then run:

```bash
cd "$HOME/Downloads/DigiSuite_Fast_Incremental_11" && bash build.command
```

The build first compiles and runs `Tests/FastBackupSmokeTests.swift` on the Mac,
then builds, signs and launches Digi Suite 1.0.11 (11). It does not quit another
Digi Suite instance. After any old backup finishes, quit the old instance and
use the newly launched build.

## Everyday workflow

1. Open the existing workspace and confirm the source and backup destinations.
2. Use Trial Sync (Preview) to see new, modified, unchanged and removed files.
3. Start Backup copies new or changed files. Existing copies with the same size
   and modification time are adopted and skipped, including prior Finder/ditto
   backups. There is no need to erase a completed backup to use this version.
4. If Automatic Backups is enabled, its existing interval now uses this same
   fast incremental path. This update does not change that preference or interval.
5. Use Folder Compare > Deep Verify and Refresh when a SHA-256 content comparison
   is wanted. Its implementation is unchanged.

The Backups status now says `Fast incremental · Size + date`. Successful targets
say `Up to date` and show copied and unchanged file counts plus elapsed time,
which remains visible after completion. The app no longer
labels an ordinary copy as checksum-verified.

## Copy and incremental behavior

- The native `FileManager.copyItem` operation performs each file copy. The custom
  streaming/hash pipeline, destination reread, and per-file forced disk flush
  are absent from normal backups. This is a macOS copy baseline, not an assertion
  that FileManager and Finder/ditto have identical performance.
- Incremental detection compares relative paths, file sizes and modification
  times, keeping the existing less-than-two-second date tolerance. It does not
  read unchanged image contents. A same-size content change with an unchanged
  date will require Deep Verify to detect.
- Source enumeration is shared between targets with identical exclusions. New
  files arriving after that snapshot are picked up by the next incremental run.
- Included empty directories are created even during a zero-file incremental run.
  Source symlinks and the backup archive are skipped. Existing per-target hidden,
  folder, extension and name exclusions remain in effect.
- A copy is staged in a unique temporary file on the destination. Source size and
  date are checked before and after copying, and copied size is checked before
  committing the file. No checksum guarantee is implied by these metadata checks.
- Existing archive-changed and archive-removed settings remain configurable and
  are preserved. Removed source files are archived only when that policy is enabled
  and the file was already tracked. Untracked extra files are not purged.
- Directory/symlink checks, containment checks and filesystem-device checks guard
  against unsafe target paths. A missing target root is not recreated.
- Progress updates are coalesced instead of awaiting a UI update for every file.
  An activity assertion covers the actual backup, preventing idle system sleep
  and App Nap during the operation; the display may sleep normally.
- Pause and Stop take effect between files. A very large file can finish its
  native temporary copy before pausing/stopping. It is not committed after Stop.
  Live byte counts advance when each file completes, rather than for each chunk.
- Two destinations still run concurrently and additional destinations queue.
  Previous manifests and existing `.digitools`/`.shootwrap` workspaces remain
  compatible. New manifest values describe metadata/copy state rather than hashes.

The optional Speed Benchmark sheet is retained as a **legacy version 10 engine
diagnostic** and now displays that limitation. Its results do not measure the
new normal-backup engine. To assess version 11, use Start Backup and its elapsed
time. An unchanged destination should finish with zero copied files.

## Evidence and validation

The same session was independently copied with macOS `ditto` on November 1:
4 TB, 5m 53s; 2 TB, 7m 11s; both reported exit status 0. The earlier version 10
copy-only tests recorded 12m 04s and 59m 07s respectively. Conditions and caching
differed between those runs, so these figures are evidence for investigating
the application path, not a promised version 11 speed or a definitive root cause.

This preparation environment has no macOS SDK or Swift compiler. Swift syntax
parsing, shell syntax, build inputs, scope preservation and package completeness
are checked here. The included Mac fixture checks cover real native copies,
metadata incrementals, existing-backup adoption, both archive modes, exclusions,
empty folders, stale sources, cancellation, path safety, shared snapshots and
progress coalescing. They run during the build on the Mac; they were not executed
in the preparation environment. Real throughput remains to be measured on Jeff's Mac.
