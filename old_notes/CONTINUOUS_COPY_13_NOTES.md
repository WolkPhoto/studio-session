# Digi Suite 13: continuous native copy queue

## Change

Version 12 waited for both members of each pair of native copies before committing
them and starting the next pair. Version 13 consumes whichever copy completes
first, commits it, and refills that slot without waiting for its partner.
There remain at most two uncommitted temporary files per destination, and two
destinations can still run at once. Each native copy uses its own FileManager.
Only the parent updates progress, commits files and changes archives.

Incremental size/date planning, exclusions, checks for changing sources, copied
file size checks, destination filesystem checks and archive policies are retained.
Normal backups do not SHA-256 hash files. Folder Compare Deep Verify remains the
optional content check. A copyOperation injection is used only by fixture tests;
the app uses native FileManager.copyItem by default.

Stop prevents committing pending files once observed, cancels queued tasks and
waits for native copies to return before deleting unfinished temporary files.
Already committed files are retained. Pause stops commits/admissions at checkpoints;
up to two already admitted native copies may finish staging before resuming.
No extra work is admitted while waiting at a pause checkpoint.

## Timing display

Destination cards now retain the stage breakdown after completion and wrap it at
narrow window widths. The display includes Total, Copy wait, Checks, Finalize,
Plan and UI time. Copy wait measures parent wall time waiting for the next native
copy, not the sum of concurrent worker durations. Copies can overlap parent checks
and commits. Worker validation is included in Checks and may overlap Copy wait;
the fields should not be added together as a wall-clock accounting identity.
Finalization includes archiving tracked removals and writing the manifest.

The primary speed comparison remains final elapsed time for the same session.
Changing drive/cache conditions are not isolated by one run, and this queue change
is a candidate optimization, not a promised fix for the entire 2 TB discrepancy.

## Measured baselines, November 1, 2026

| Full copy | 4 TB | 2 TB |
|---|---:|---:|
| Earlier Terminal ditto | 5m53s | 7m11s |
| Digi Suite 11 | 9m51s | 12m36s |
| Digi Suite 12 | 6m47s | 10m43s |

Version 12 copied 36,699 files / 256.22 GB to each drive. A simultaneous unchanged
rerun reported zero copied, 36,699 unchanged on each, in 4s (4 TB) and 3s (2 TB).
Jeff saved the workspace afterward. Version 11 also passed added/edited file
tests to both drives, with destination text contents confirmed by Jeff.
Version 13 has no measured throughput result yet.

## Build and focused test

Quit the previous Digi Suite when backups finish, extract into Downloads, then:

```bash
cd "$HOME/Downloads/DigiSuite_Continuous_Copy_13" && bash build.command
```

This creates, signs and opens Digi Suite 1.0.13 (13). The build first runs native
backup fixtures on the Mac. Existing tests cover real file bytes, archives,
incrementals, symlink safety and parallel targets. Added deterministic tests hold
one copy open until a third starts (a paired queue would time out), assert the
two-worker bound, and inject partial-copy failure/Stop to check drain and cleanup.

Swift syntax, shell syntax and package scope are checked in the preparation
environment. No Swift compiler or macOS SDK is available there, so Mac compilation
and fixture execution occur during the build on Jeff's machine.

For speed, use Start Backup with only the 2 TB configured and a new empty test
folder on that drive. Keep the completed backups. Compare against version 12's
10m43s; capture the final retained stage breakdown. The optional Speed Benchmark
still uses the old version 10 engine and does not measure this queue.

Earlier version 11/12 notes are historical; this file and the version 13 command
above describe this package.
