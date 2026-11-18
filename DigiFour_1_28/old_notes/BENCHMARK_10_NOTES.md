# Digi Suite 10: Backup Speed Benchmark

This development source adds **Backups > Speed Benchmark...** to the existing
nine-tab Digi Suite app. It is based on `DigiSuite_Bounded_Verified_Pipeline_09`.
Normal backups keep the existing SHA-256 copy/verify engine, manifests, filters,
archive rules and parallel-destination behavior.

## Build and launch

Requires Apple Silicon, macOS 14 or later, and Xcode Command Line Tools.
Extract the ZIP into Downloads, then run:

```bash
cd "$HOME/Downloads/DigiSuite_Backup_Benchmark_10" && bash build.command
```

The build first compiles and runs the small benchmark safety checks, then
compiles, signs and launches Digi Suite 1.0.10 (10). No application is quit by
the script. Let an older instance's backups finish and quit that instance before
starting the benchmark; the benchmark detects another running Digi Suite instance.

## Use

1. Open **Backups > Speed Benchmark...**.
2. The source and first two destinations default to the current workspace.
   Use Change to pick a smaller representative source if desired.
3. Choose which mode runs first, then click **Run Benchmark**.
4. Allow the suite to finish, then click **Export CSV...**.

With two targets, tests run in this order:

| Configuration | Modes |
| --- | --- |
| Target A alone | Copy only, Copy + SHA-256, in the selected mode order |
| Target B alone | Copy only, Copy + SHA-256, in the selected mode order |
| Both together | Copy only, Copy + SHA-256, in the selected mode order |

That is six timed tests and eight per-destination result rows. Each target
receives four full test copies over the suite. With one destination, only that
destination's two tests run. The full source is read for each destination;
the tests do not select a smaller random sample automatically.

## Temporary data and cancellation

- Each test writes into a new, uniquely named `_DigiSuite_Benchmark_<UUID>`
  child folder of the selected destination. Its data lives under `Data/`.
- Cleanup requires the exact parent, generated path and ownership token, and
  rejects a changed/symlinked scratch root. Existing backup data is not used as
  a copy target or removed by cleanup.
- Temporary test copies are removed after each test, including a normal Stop.
  Transfer time excludes source revalidation and deletion time.
- Stop prevents later tests, interrupts copy/hash work and waits for hashing
  workers before cleanup. Cleanup failures identify the remaining folder and
  are included in the CSV. A force quit can leave scratch data behind.
- The suite refuses overlapping source/destination paths, checks free space,
  checks real mounted-volume availability, and checks for source changes.
- All included files use the same inventory across targets and modes. Hidden
  files are off by default and can be enabled. Symlinks and the backup archive
  are excluded. Per-destination production backup exclusions are not applied.

## What the timings mean

The benchmark engine mirrors version 09's 4 MiB streaming copy, inline source
SHA-256, 1 MiB destination hash reads and bounded two-file copy/verify overlap.
It is a separate diagnostic engine so copy-only is unavailable to normal backups.
Fresh scratch copies do not need production incremental-manifest or archive
bookkeeping; their totals should not be treated as identical to an incremental
production backup.

- **Copy:** time in streaming copy, including source hashing in verified mode.
- **Verify:** accumulated destination SHA-256 read time; zero for copy-only.
- **Target total:** actual elapsed time for one destination's transfer.
- **Test total:** actual elapsed time until all destinations in that trial finish.
  For the paired trial, both rows share this total.
- **Planning/finalize/cleanup:** also available separately in the CSV.

Copy and verification overlap. Stage durations must not be added together or
subtracted from total to infer idle time. Effective MB/s is completed logical
bytes divided by elapsed time, not physical device traffic.

The initial source inventory is measured separately. Source size and modification
time are checked during copying, with fresh metadata reads; a fresh inventory
after each trial detects added/removed/changed files or folders and invalidates
a comparison if the source changed. Use a stable test folder.

macOS caching stays enabled and is not cleared. Copy-only and verified tests
write fresh files every time, but earlier runs can warm the source/cache. Pause
other disk-heavy work and repeat with the mode order reversed to check order
effects. A single difference is not proof that all production idle periods are
caused by SHA-256.

## Application coordination

While a benchmark runs, new normal backups and preview syncs are held, scheduled
backups retry on their next interval, and new Dashboard inventory scans defer.
The quit warning also covers an active benchmark. Capture One session offers
defer while the benchmark runs. Previously deferred Dashboard scans resume when
it finishes. Other tools and the approved interface are retained.

## Validation

This source was prepared on Linux, without a macOS SDK or Swift compiler. All
Swift source files were syntax-parsed with a Swift tree-sitter grammar, shell
scripts were checked, the normal production copy/verify routines were compared
against version 09, and the source ZIP was checked for completeness. These
checks do not establish a successful macOS compile or runtime result.

`build.command` runs `RUN_BENCHMARK_TESTS.command` on the Mac before building
the app. The fixture checks both modes, copied bytes, known SHA-256 output,
mismatch handling, two concurrent destinations, empty folders, hidden-file
selection, symlink exclusion, cancellation, source changes, overlap rejection,
CSV quoting, and refusal to delete an unowned folder. It creates and removes
only its own temporary fixture directory.

For benchmark safety checks alone:

```bash
bash RUN_BENCHMARK_TESTS.command
```
