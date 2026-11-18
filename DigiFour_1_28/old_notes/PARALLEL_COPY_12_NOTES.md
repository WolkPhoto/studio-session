# Digi Suite 12: bounded parallel native copies

## Focused change

Version 11 issued one synchronous FileManager copy per destination at a time.
Version 12 stages two independent native copies concurrently in each batch.
Each worker uses its own FileManager. Commit, archive and UI state updates stay
on the parent task. At most two temporary files exist per destination; with two
active destinations there can be four native copies across both drives.

This is an experimental throughput change, not a measured speed improvement.
Concurrent I/O can also be slower on some storage. The code exposes a serial
reference through the internal copyConcurrency parameter for fixture comparison.
No Swift compiler or macOS SDK is available in the preparation environment.
The Mac build runs the included fixture tests before compiling the application.

## Behavior and limits

Size/date incremental planning, source stability and copied-size checks, filters,
manifest compatibility, and both archive policies are retained. Folder Compare
Deep Verify remains the optional SHA-256 path. Each batch is fully drained before
temporary cleanup, including on failure or cancellation. Stop waits for up to two
in-flight native copies per destination, and does not commit them after the stop
request is observed. Pause waits at batch/file boundaries. Already committed files
are retained. Copy stage timing is batch wall time rather than overlapping worker
durations added together. Progress advances as staged files are committed.

## Confirmed version 11 results on Jeff's Mac, November 1

Session: 2026_10_14_LIG_GO. 36,698 files, 256.22 GB.

| Operation | 4 TB | 2 TB |
|---|---:|---:|
| Earlier Terminal ditto copy | 5m53s | 7m11s |
| Version 11 fresh backup | 9m51s | 12m36s |
| Version 11 unchanged incremental, both drives active | 3s | 3s |
| Version 11 added file, both drives active | 3s | 3s |
| Version 11 edited file, both drives active | 3s | 3s |

Destination contents of the edited test file were confirmed by Jeff. Version 11
built and ran on his Mac. The mid-copy 2 TB screenshot showed Copy 688.8s,
Checks 7.6s, Finalize 2.8s and Plan 1.0s out of Total 701.7s. This localizes most
measured time to the native copy calls. It does not prove the speed gap's cause.
Different cache and background conditions limit comparison with earlier ditto.

## Build and test

Quit the previous app after backups finish. Extract into Downloads and run:

```bash
cd "$HOME/Downloads/DigiSuite_Parallel_Copy_12" && bash build.command
```

The build creates Digi Suite 1.0.12 (12), runs backup fixtures, signs and launches.
Fixtures retain version 11 cases and add parallel/serial byte comparisons,
odd batches, zero-byte and larger files, unchanged reruns, and temporary cleanup.

Keep completed backups. Use Start Backup with one new empty test destination
on the 4 TB drive to compare against version 11's 9m51s. Do not use the legacy
Speed Benchmark, which runs the version 10 engine. If throughput improves,
repeat on the 2 TB. Then use the normal existing destinations for incremental
runs. New/edited files should copy, and matching files should skip.

FAST_INCREMENTAL_11_NOTES.md is retained as historical architecture context.
Use this file and the version 12 build command for this package.
