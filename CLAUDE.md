# Digi Suite: project notes for Claude Code

Owner: Jeff, working photographer / digital tech (Capture One). Native macOS
SwiftUI app, Apple Silicon, macOS 14+. Bundle ID `com.digitools.app`.
Current version: 1.38.0 (folder `DigiFour_1_38`). One codebase; since 1.25 only Studio Session (BRAND_GRIP) is built and released. Wrap, Proof, Tally and classic code remain, unused.

## Build and test

```bash
bash build_grip.command      # or build_wrap / build_proof / build_tally
bash build_all.command       # Studio Session only (since 1.25): tests, build, open
bash build.command           # classic Digi Suite
```

build.command reads APP_NAME, BUNDLE_ID, BRAND (passes -D BRAND_<NAME>),
NO_OPEN and SKIP_TESTS. Dock icons are made on the Mac from brand/<key>/icon.png
with sips + iconutil. Each app has its own bundle ID (com.digitools.<key>), so
settings, tour state and permissions are separate.

Runs the headless backup tests first (`RUN_FAST_BACKUP_TESTS.command`), then
compiles with `xcrun swiftc` (file list is in build.command), signs with
Jeff's Apple Development identity if present, and opens the app. New Swift
files must be added to build.command, and to RUN_FAST_BACKUP_TESTS.command if
the tests need them. Existing warnings (Sendable, captured vars, deprecated
onChange) are inherited from v13; they do not break the build.

Swift type-checker note: dense one-line expressions (ternaries mixed with
arithmetic, `??` inside string concatenation, long `&&` chains of optional
comparisons) have caused "unable to type-check in reasonable time" errors.
Write them as separate typed statements.

## Layout

- `ShootWrap.swift`: WrapModel (state, backup orchestration), main UI, nine tabs.
- `DigiStreamEngine.swift`: **Digi Stream**, the only copy engine (v17+).
- `FastBackupCore.swift`: shared types (SyncProgress,
  BackupFilter, BackupControl with parent/child controls), planning
  (`snapshot`, `plan`), manifest/archive constants, free-space helper.
- `DriveCheck.swift`: USB link speed (parses `system_profiler SPUSBDataType`
  text; APFS volumes are traced to their physical disk with `diskutil`),
  free space, format.
- `Tests/FastBackupSmokeTests.swift` (entry point), `Tests/StreamEngineSmokeTests.swift`,
  `Tests/FolderPlanSmokeTests.swift`.
- `FolderMaker.swift` (UI) + `FolderPlanCore.swift` (Swift engine, v20; Python removed).
- Five-app layer (v21): `Brand.swift` (names, themes, tool names, tour text per
  brand, chosen at compile time), `BrandKit.swift` (backup snapshot, the single
  "next step", tour coach card, shared buttons), `BrandMarks.swift` (drawn logos),
  `ShellGrip/Wrap/Proof/Cart/Tally.swift` (each app's navigation). ShootWrapView
  splits into `classicWorkspace`, `brandedWorkspace` and shared `toolContent`;
  the nine tools are identical in every app. Cards use `DigiBrand.cardFill`, accents
  `DigiBrand.accent`. Menu Navigate has Cmd-1..9 per tool ("tool:N" command).
- `DigiDestinationLock` (FastBackupCore): one app at a time per backup folder,
  lock files in ~/Library/Application Support/DigiTools/Locks (never on the drive).
- `Installer.swift` (20.11): launch offer to copy into /Applications + Dock; menu item
  Digi Suite > Install in Applications / Dock. Old copy goes to Trash.
- Other tabs: FolderCompare,
  ContactSheets, JobReport, MetadataWatcher, SessionComposition. Do not
  change them while working on backups.

## Backup engine facts

- Digi Stream: files >= 8 MiB copied one at a time, 16 MiB chunks, F_NOCACHE
  writes into F_PREALLOCATE'd space; smaller files 4 at a time via copyfile.
  Temp file `.shootwrap-UUID.tmp` -> source-unchanged check -> size check ->
  set mtime -> archive/replace/move. Pause/Stop work mid-file.
- The Classic (v13) engine was removed in v18 at Jeff's request. Manifest
  (`.shootwrap-sync-manifest.json`) and archive layout
  (`_ShootWrap_Archive/<stamp>/Replaced|Removed from source/`) are unchanged,
  so older backups stay incremental.
- Incremental rule: same size and modification time within 2 s = unchanged.
  No routine hashing; content checks are Folder Compare > Deep Verify.
- Never recreate a missing destination root or /Volumes mount. Never follow
  symlinks. Source and destination must not contain each other. Do not
  disable the "Source changed during backup" check.
- Up to 4 destinations copy simultaneously (`maxSimultaneousDestinations`); more queue.
- Drives added mid-backup join via `joinRunningBackup`; `runningBackupJobs` and
  `finishBackupIfIdle()` decide when the whole backup is done.

## Measured results (Nov 1, 2026, M3 MacBook Pro, 256.22 GB / 36,700 files)

| Run | Drive state | Time |
| --- | --- | --- |
| Digi Stream (v17) | 2TB T7, freshly erased APFS, 10 Gb/s | 6:30 (657 MB/s avg, flat graph) |
| ditto, same drive right after | same | ~270 MB/s, stopped at ~163 GB after 10 min |
| ditto, morning | 2TB HFS+, fresh-ish | 7:11 |
| CCC / Classic v13 | 2TB HFS+, afternoon | 10:14 / 10:31 |
| v16 (Classic engine) | 2TB HFS+ after repeated delete/recopy | 17:02, burst-and-stall graph |

Lessons: cached writes (Classic, ditto, CCC) showed burst-and-stall on these
SSDs; Digi Stream's uncached stream stayed flat. HFS+ over USB does not get
freed space reported to the SSD, so repeated delete/recopy degrades it;
erasing as APFS fixed it. Judge speed only with the drive at 10 Gb/s and not
nearly full; compare engines on the same drive in the same state.

## Drives

- `/Volumes/WolkPhoto2TB`: Samsung T7 2TB, now APFS.
- `/Volumes/wolkphoto4TB`: Crucial X9 Pro 4TB, HFS+, about 93% full.
  Candidate for the same APFS erase, only after Jeff confirms its other data
  exists elsewhere.

## Working with Jeff

- Never delete, erase or overwrite anything on backup drives, or Jeff's
  files, without his explicit go-ahead. Destructive steps are his call.
- Do not claim a speed improvement until it is measured; separate facts
  from guesses. No long test matrices; one fair comparison at most.
- Every delivered version gets THIS exact one-line build command (Jeff's standing request, Nov 9).
  It refuses while the app runs, then unzips the newest DigiFour_*.zip in Downloads and builds:
  `pgrep -f "Studio Session.app/Contents/MacOS" >/dev/null && echo "Quit Studio Session first (stop any backup), then run this again." || (cd ~/Downloads && Z=$(ls -t DigiFour_*.zip | head -1) && D=$(zipinfo -1 "$Z" | head -1 | cut -d/ -f1) && echo "Building $D from $Z" && unzip -o -q "$Z" && cd "$D" && bash build_all.command)`
- Before switching versions: stop any backup, wait, quit the old app. Confirm
  the running build with
  `pgrep -fl "Digi Suite.app/Contents/MacOS/Digi Suite"`.
- Keep the established dark compact UI; layouts must resize cleanly.
- UI must show exactly what will happen: no rows, counts or labels that
  suggest an action the app will not take. Simple first; add options later.
- Selections must be visibly confirmed (selected button filled/checked).
- A button the user clicks must always visibly respond; if there is nothing to
  do, say why in a simple dialog that Return closes.
- No em dashes in written replies.
- GitHub (jsw513/studio-session): ask Jeff before every push. Day-to-day versions go out as zips
  only; push when he says so (for example a release).
- Keep SwiftUI body work cheap: never loop over scan results or file lists in a view body;
  cache totals when data changes (window resizes redraw constantly, see 20.10).

## Results added later (Nov 1, evening)

- Two drives at once (2TB T7 + 1TB T7, fresh APFS): 6:22 and 8:24, 512 GB
  in 8:24, about 1,179 MB/s combined. Each drive drops once its fast write
  area fills (1TB earlier and lower).
- 4TB X9 Pro, HFS+, 93% to 99% full: 9:23, slowing near the end as it filled.

## UI work

Jeff wants UI changes one tab at a time. v18 reworked the Backups tab (see
BACKUPS_UI_18_NOTES.md). He picks the next tab. v19 fixed Dashboard session loading (DASHBOARD_19_NOTES.md). v20 rebuilt Folder Maker (FOLDER_MAKER_20_NOTES.md); Jeff's main use is turning client spreadsheets, emails and shot lists into folders. He removed smart email interpretation (20.3) until AI help is available; Paste List is one folder per line. Import is one column = one folder per cell (20.4); Jeff wants it simple now, maybe more later.

## Open items

1. 4TB: erase as APFS (after Jeff confirms) and run a two-drive Digi Stream backup.
2. Measure Digi Stream after a large delete on APFS (does speed hold?).
3. Metadata Watcher: make ExifTool `_original` backups optional (requested, not built).
4. Swift 6 / deprecation warning cleanup (low priority).

## Five apps (v21, Nov 2 overnight build)

Built per Jeff's plan: identical functionality and engine, different brand, feel
and navigation; first-time-user friendly ("my 13 y/o could figure it out"); tour on
first launch (coach card, skippable, Help menu brings it back). START_HERE.md has
the lineup and build commands. 1.0 compiled clean on the first try (Nov 2, 7:28). Brand boards: claude.ai artifact "Grip Brand Refresh".

### 1.1 (Jeff's first review)
- Wrap: suggestion list opens only on Cmd-K, typing, Down arrow or a click; closes on run, Escape, blur.
- Proof: no step numbers (icons instead, check when done); Cmd-1..9 follow screen order
  (DigiBrand.toolOrder); sections can be hidden by right-click.
- Grip: collapsible sidebar (Ctrl-Cmd-S), icons plus status light and next-step icon when collapsed.
- All five: right-click a tool to hide it (shared key DigiSuite.hiddenTabs.v1, Home can't be hidden),
  "Show N hidden tools" button, Navigate menu numbers follow visible on-screen order.
- Jeff: Tally feels most like Digi Suite (asked whether to rethink or drop). Tech Cart not reviewed yet.

### 1.2
- Tech Cart navigation reworked (Jeff disliked the tile home + Home button): big status bar
  on top, row of big tool buttons with live status along the bottom, one click to switch.
- Plan discussed: keep Grip, Wrap, Proof, Tally; Tech Cart may be dropped later and its big
  status numbers folded into the others as an optional "Cart Mode". Jeff wanted to glance at 1.2 first.

### 1.3
- Tech Cart scrapped by Jeff (bottom tool buttons took too much room). Its build script, icon and
  build_all entry are gone; ShellCart.swift and the BRAND_TECHCART branch remain in the code,
  unused, so nothing else had to change. Remove them in a later cleanup.

### 1.4 (Jeff's second review)
- Drag a tool off its bar to remove it with a poof (DigiPoofDrag): rows drag down, Grip's sidebar
  drags right. Right-click Hide and Show hidden tools still work.
- Windows: .defaultSize(1360x1040) on first launch; DigiWindowFrameSaver sets an NSWindow frame
  autosave name so later launches reopen at the user's size.
- Menu bar (all apps): status, Back Up Now (or the next step), Pause/Resume/Stop while running,
  Stop Watching Metadata Folder only while watching, Backup Schedule (opens Backups), per-app icon.
- Metadata Watcher is now one shared model with its own 2 s timer (MetadataWatcherModel.shared);
  before, it stopped whenever you left its tab.
- Wrap: search bar removed (command code left unused). Proof: Set Up renamed Dashboard, Folders
  is its own section. Tour: "Later" (shows next launch) and "Don't Show Again"; small ? button
  bottom right brings it back; header tour buttons removed.
- 1.4.1: compile fix. Timer closure used [weak self] inside a Task ("captured var self in concurrently-executing code"); now calls MetadataWatcherModel.shared.tick() via MainActor.assumeIsolated.

### 1.5
- 1.4.1 built and runs. Tally: tool buttons stretch to fill the row (maxWidth .infinity); the eye
  button is now a + menu (DigiAddToolMenu) listing hidden tools to add back, plus Add All Back.
- Jeff now builds by double-clicking "Build Digi Apps.command" on his Desktop: it picks the newest
  ~/Downloads/DigiFour_*.zip, unzips without overwriting, runs build_all. Keep zips named DigiFour_*.

### 1.6
- DrivePermissions.swift: when a backup folder or drive isn't writable, explain and offer "Fix
  Permissions", which runs `diskutil disableOwnership /Volumes/<drive>` with admin rights via
  AppleScript (macOS asks for the password). Same as Finder's "Ignore ownership on this volume".
  Read-only volumes (NTFS, locked) get an explanation instead. Hooked into addBackup,
  addDiscoveredBackupDestination and createDiscoveredBackupFolder.
- Jeff reported "backup engine broken": 293 MB/s avg, burst-and-stall graph, to Backup_KK_CHOA_042021
  (2TB, HFS+, 771 GB free). DigiStreamEngine.swift is byte-identical to 20.11; only the destination
  lock was added (once per drive). Pattern matches the documented HFS+ degradation. Suggested one fair
  test: same session to the APFS T7 (WolkPhoto2TB), expect about 6:30.

### 1.7
- Export Check (Processed Files Check): cards were a hard-coded near-black, unreadable in Proof's
  light theme. Brands now use DigiBrand.cardFill (classic unchanged). Folder cards show an
  "Auto-selected" / "Chosen by you" badge, a bigger folder name, and the full path in a readable box.

### 1.8
- Proof: Light / Dark / Match System (sun/moon menu in the top bar, key Proof.appearance).
  DigiBrand.theme is now computed: Proof picks fixedTheme or darkTheme; other apps keep their one
  look. ShootWrapView re-identifies mainWorkspaceView when the look changes (open tool state resets).
  Selected sub-tool pills use the accent so they read in both looks.
- Before a manual backup, drives that aren't APFS get a warning (HFS+, FAT/exFAT, other) in the same
  dialog as the slow-link warning, with "Don't warn me about this drive's format again" (stored by
  volume name in DigiSuite.formatWarningSkipped). Scheduled backups never prompt.
- Tally: name and tagline in the title bar strip, slimmer status band.

### 1.9
- Top gap fix: hiddenTitleBar still reserved the top safe area AND the shells added titleBarInset,
  doubling the gap. Brands now ignore the top safe area (DigiTitleBarSpace) so titleBarInset is the
  only space. Tally and Proof put their name centered on the window-button line (not clickable,
  so window dragging there is unaffected). Proof's session chip, appearance menu and show-hidden
  moved into the next-step strip.

### 1.10
- Proof Light/Dark switch drew system controls (labels, checkboxes, segmented control) in the old
  look until the next redraw: the .id rebuild ran before the window's appearance changed.
  DigiAppearance.apply sets NSApp.appearance synchronously in the picker's setter (and on launch);
  other brands are forced dark, classic follows the Mac.

### 1.11
- Grip: "GRIP" + mark + tagline centered on the window-button line (brandStrip); sidebar loses its
  logo row (now a small TOOLS label + collapse toggle); header padding trimmed.
- Sounds: finishBackupIfIdle plays "Glass" when all drives are up to date, "Basso" on any problem,
  nothing when the person stopped it (WrapModel.playOutcomeSound). Key DigiSuite.sounds; default on
  in Tally, off elsewhere (DigiBrand.soundsDefault). Toggle in every app's menu bar menu and Tally's panel.

### 1.12
- Rearranging: DigiArrangeDrag replaces DigiPoofDrag. Drag along the bar to move (sideways in rows,
  up/down in Grip's sidebar), across it to remove with the poof. Order saved per app in
  DigiBrand.toolOrder.v1 (DigiToolOrder); DigiBrand.toolOrder is now computed (defaultToolOrder
  when unset). Proof moves whole sections; its section order comes from the tool order.
  Shells and the App menu observe the key so everything (and Cmd-numbers) follows the new order.

### 1.13
- Rearranging shows a landing mark: an accent-colored line between the two tools where the dragged
  tool will drop (DigiArrangeDrag overlay, slot = item size + 6 pt gap). Hidden while removing.

### 1.14
- Jeff's default tool order (Grip, Wrap, Tally): Home/Status, Folders, Backups, Compare, Contact
  Sheets, Exports, Selects, Report, Metadata = [0,4,1,7,6,3,2,5,8]. Proof: Dashboard, Folders,
  Back Up, Verify, Deliver (Contact Sheets, Exports), Selects (+Metadata), Wrap Up = [0,4,1,7,6,3,2,8,5].
  Navigate > Reset Tool Order returns to it. Saved orders (from dragging) still win.

### 1.15
- Folder Compare: clicking a verification mode (Quick, Standard, Deep Verify) runs it right away
  (unless fewer than 2 folders or a backup is running). Opening the tab still never starts Deep Verify.

### 1.16
- Capture One session dialog: selection lived in ShootWrapView @State, so each click redrew the
  whole window (about 5 s to show). SessionProposalSheet now owns its selection, preselects the
  first/only session, and uses large row buttons instead of a radio group.

### 1.17
- Session dialog row back to a plain line; only the radio circle turns blue (Jeff: the accent-colored
  row read like a warning in Tally's red). Selection stays instant (own @State).
- build_all now builds only Tally and Grip (Jeff's choice). Wrap and Proof scripts and code remain.
- Grip rename under discussion: suggested Darkslide (pick), Rig, C-Stand, Lightbox, Sandbag.

### 1.18
- Grip renamed "Studio Session" (Jeff's pick). Display name, title strip, tour, app bundle
  (Studio Session.app). Code names (BRAND_GRIP, ShellGrip, GripMark) and bundle ID com.digitools.grip
  unchanged on purpose, so Jeff's saved order, hidden tools, tour state and window size carry over.

### 1.19
- Studio Session: the centered title strip didn't show in Jeff's 1.18 screenshot. Now the brand
  (GripMark + STUDIO SESSION) sits at the top of the sidebar (mark only when collapsed), and the
  tagline strip is drawn as an overlay on the window-button line. Header title 26 -> 21, padding
  trimmed; Home "Next" card smaller (icon 44, title 20, padding 14, top gap 12).

### 1.20
- Studio Session: tagline strip removed (Jeff). Only the sidebar keeps the window-button gap; the
  main column's header starts at the top (12 pt padding).
- "Choose a backup drive" next step detail (all apps): "Plug in drive(s), get these files to safety."

### 1.21
- release.command: Developer ID signing (hardened runtime, timestamp, DigiApp.entitlements), notarize
  the app (zip) and staple, DMG with an Applications link, sign + notarize + staple the DMG,
  spctl check. Output ~/Desktop/Digi Releases. Notary keychain profile "DigiNotary" (set up
  interactively on first run with the team ID from the certificate). Log: release_log.txt.
- DigiApp.entitlements: com.apple.security.automation.apple-events (Capture One session lookup via
  osascript under the hardened runtime). build.command now signs with it too.

### 1.22 (Folder Maker)
- Create In: Command-click adds a place (Session, Capture, Output, Chosen Folder), Command-click a
  chosen one to take it away; a plain click picks only that one. Key
  DigiSuite.folderMaker.destinationChoices ("capture,output"); the old single key still sets the first.
  Places are de-duplicated by path. Preview counts and statuses cover every place ("New in 1 of 2").
  Create, Undo and Show in Finder work across all of them; the confirm dialog lists every path.
- Pictures of shot lists: FolderImageText (Apple Vision, VNRecognizeTextRequest, accurate, on-device)
  reads png/jpg/heic/tiff/gif/bmp/webp from Choose File or a Finder drop, image data dropped from
  another app, and a copied picture via Paste from Clipboard. Lines go into Paste List, top to bottom.
  build.command links -framework Vision.
- Spaces in names: Keep / Use _ / Use - (key DigiSuite.folderMaker.spaces), every level incl.
  subfolders. FolderPlan.replaceSpaces (tested): " - " becomes "-", other spaces the separator.
  Preview shows "→ new_name" beside a name it changes.
- Studio Session tour: Command-number text no longer claims Command-2 is Copy.

### 1.23
- Paste List gets its own "Read a Picture…" button (image-only open panel, same Vision reader) and a
  spinner while reading; its help line explains the picture options (Jeff: the option was only visible
  in Import File).

### 1.24
- Jeff: an older Capture One Pro kept opening by itself. Cause (likely): the session monitor and the
  Selects scan used `tell application "Capture One"`, which macOS resolves by name and launches if
  needed, possibly an older copy. Now CaptureOneTarget picks the running Capture One (newest launch)
  and scripts say `if not (application "<its path>" is running) then return ""` + `tell application
  "<its path>"`. The Selects scan stops with "Open Capture One with this session first" if none runs.

### 1.25 (Studio Session only; DT review fixes)
- Jeff: work only on Studio Session from now on. build_all and release build just it.
- Checksums (DigiChecksum.swift): XXHash64 (streaming; matches xxHash's published test values,
  checked in StreamEngineSmokeTests), DigiChecksum.hashFile. Engine `sync(verify:gate:)`:
  large files hash the source from the copy buffer, then read the temp file back (F_NOCACHE) and
  compare before commit; small files hash source + read back after copyfile. A mismatch deletes the
  temp and copies once more, then fails with ChecksumMismatch. Small-file read-back may be served from
  memory (copyfile writes are cached); large files are written uncached so their read-back hits the drive.
  Default on (DigiSuite.verifyCopies). Slower: not measured yet.
- DigiBackupReport: `_StudioSession_Reports/Checksums.xxh64` (cumulative, xxhsum -c format, pruned to
  current source files) and "<yyyy-MM-dd HHmm> Backup Report.txt" per run with copies (nothing new =
  no report). SyncProgress.verifyOn/verifiedFiles/reportPath; the drive card shows "N of M verified"
  and Open Backup Report.
- Capture One: DigiCaptureGate sets this thread's disk I/O to IOPOL_UTILITY while Capture One runs
  (DigiSuite.gentleWhileCapture, default on; probe cached 2 s). Session monitor: 12 s while nothing is
  found, then 45 s; lsof/osascript run at .background QoS; osascript only when 2+ sessions are open.
- Archive: new name `_StudioSession_Archive`; `_ShootWrap_Archive` still recognized
  (DigiFastBackupEngine.archiveNames / toolFolderNames, skipped by snapshot, syncInventory, benchmark
  scan and Folder Compare at the root). DigiArchive.swift: measure, runs (oldest first by ISO stamp),
  clearAll, trimOldest(keepFree:) — deletes only inside the archive folders. Drive card: size +
  Clear… (NSAlert, Cancel is the default button, Delete is destructive). Auto-trim before and after each
  backup when on (DigiSuite.archiveAutoTrim, archiveAutoTrimGB default 100), noted in SyncProgress.archiveNote.
  Manifest name `.shootwrap-sync-manifest.json` unchanged on purpose (incrementals keep working).
- Metadata hidden in Studio Session: DigiBrand.retiredTools = [8] (toolOrder filters it; tool:8 command ignored).
- DigiUpdater.swift: Check for Updates (app menu) + daily background check 8 s after launch
  (DigiSuite.autoUpdateCheck). GitHub API releases/latest of Info.plist DigiUpdateRepository
  (build.command UPDATE_REPO or UPDATE_REPO.txt). Download opens the release's .dmg. Skip This Version.
- GitHub: publish_github.command (gh install/sign-in, creates repo; private code gets a public
  <name>-releases repo for DMGs; permanent clone ~/Developer/StudioSession; later runs rsync + commit +
  push). release.command offers `gh release create v<version>` with RELEASE_NOTES.md.

### 1.25 test results (Nov 5, T7 WolkPhoto2TB APFS, 10 Gb/s, Capture One closed)
- Full verify, 256.22 GB / 36,700 files, new folder: 15:32 (avg ~293 MB/s counted as written bytes;
  ~350-400 MB/s most of the way, dropped to ~100 MB/s for the last ~15%). Nov 1 without checksums: 6:30.
  A same-day run with checksums off has not been done yet, so the split between read-back cost and
  drive state is unknown.
- Report for that run was 4 MB / 36,725 lines (every file listed) -> shortened in 1.26.

### 1.26
- Read-back overlaps copying: large files are copied with copyLarge(verify:, readBack: false), then a
  separate task (startCheck, LaneResult.checked) reads the temp file back while the next large file
  copies. At most one read-back at a time; copies run at most two files ahead (waitingChecks). A
  mismatch removes the temp and re-admits the file once (Staged.attempt), then ChecksumMismatch.
  Small files still verify inline after copyfile. Speed effect not measured yet.
- Checksum modes (DigiSuite.verifyMode: full / quick / off; 1.25's DigiSuite.verifyCopies=false maps to
  off): Quick = sync(verify: true, readBack: false), originals hashed while copying, no read-back;
  SyncProgress.readBackOn; report says Quick. A "Checksums: …" menu replaces "Digi Stream · Size + date"
  on the backup control bar; segmented picker + explanation in the options.
- Report: per-folder totals (DigiBackupReport.group = first two path levels, up to 80 groups), no
  per-file list (that's Checksums.xxh64), file name stamp now yyyy-MM-dd HHmmss.
- Sidebar backup panel: time left under the bar and per drive ("Copying 65% · about 3 min left",
  DigiBackupSnapshot.etaText / eta); next-step Pause icon is pause.fill (was the sync arrows).
- Check: waiting message "Waiting for the backup to finish, then checking automatically" and it runs
  when autoRefreshAllowed turns true (Quick/Standard; Deep Verify still needs a click).
- Eject of a drive that's already gone: "<name> is already unplugged. Nothing to eject."
- Connected-drive folder suggestions use the backup source's name (syncSource ?? root), not the
  Home session (Jeff saw "testing" while backing up 2026_10_14_LIG_GO); refreshed when the source changes.

### 1.26 test results (Nov 5, T7 freshly erased APFS before the Full run, fans on, Capture One closed)
| Mode | Time |
|---|---|
| Full verify (overlapped read-back), fresh erase | 14:30 (avg 294 MB/s write; dip to ~100 MB/s at ~215 GB, recovered) |
| Quick, after 10 min idle, new folder | 7:04 (601 MB/s, flat) |
| Nov 1, no checksums, fresh erase | 6:30 |
- Reading back on the same USB drive while writing halves write speed and keeps the T7's fast cache
  from draining. Overlap gained ~1 min only. Sustained writes after repeated delete/rewrite fell to
  30-100 MB/s (drive state / heat), so speed tests need a rested, cool drive.
- Rename test: 38 images renamed in Capture One -> 188 files (2.5 GB) recopied in 8 s, 2.5 GB archived.

### 1.27
- Full verify = copy everything first (Quick speed), then one read-back pass over every new copy
  (postVerify, copiedChecks). Mismatch -> repair(): fresh copy from the original, checked as written
  (copyLarge/copySmall readBack: true), replaceItemAt, SyncProgress.repairedFiles; second failure ->
  ChecksumMismatch. The 1.26 overlap path is off (pipelineReadBack = false), code kept.
  Progress/ETA cover copy + read (bar = (copied + verifiedBytes) / 2 x total); copy MB/s unchanged
  during the pass. Graph: read-back samples from SyncProgress.readSampleStart drawn in blue, legend.
- Rename detection (findRenames, only with "Archive tracked files removed" on): a new file whose size,
  date and extension match a file that left the session, with equal contents (original's xxHash64 vs
  the backup copy's recorded checksum, or the backup copy hashed when none recorded), is moved on the
  backup instead of copied + archived. SyncProgress.renamedFiles; checksum list follows the rename.
- Graph hover (onContinuousHover): line + "2:14 in · 582 MB/s · 78 GB copied" / read-back variant.
- Checksum choice only on the backup bar (Checksums ▾) with its explanation under the bar when idle;
  removed from the schedule options. Counts line: "N copied · N verified · N renamed · N unchanged"
  (Quick: "N copied, checksummed"); SyncProgress.checksummedFiles.
- Report: "Copied this run (read back and verified | checksummed)", renamed, re-copied and archived
  counts, "1 file" plurals, method text for verify-after-copy, stopped-during-verify note.

### 1.27 test results (Nov 5, T7, Capture One closed)
- Full verify (copy, then read back), new folder after a large delete: 13:23. Copy ~7 min at ~600 MB/s,
  read-back ~6 min at ~680-700 MB/s (the T7's read speed). Files fully on the drive at ~7 min.
- Rename test vs that backup: 38 copied (50 MB: Capture One .cos settings + session db), 140 renamed
  (raw + previews), 39 archived (50 MB), 5 s. 1.26 copied 188 files / 2.5 GB for a similar rename.
- Jeff: keep Full verify the default. Launch update check stays silent unless there's an update
  ("You're up to date" only from the menu).

### 1.28
- Copy speed and verify time apart: SyncProgress.copyPhaseSeconds / verifyPhaseSeconds; bytesPerSecond
  frozen when the read-back pass starts (copyRateFrozen). DigiLastBackup.verifySeconds (optional):
  "Last backup: … copied in 7m 02s at 607 MB/s, verified in 6m 21s".
- Sidebar says "Verifying 68%" in the read-back pass (DigiDriveLine.verifying).
- Short backups: no empty graph or legend, no "Peak 0.0 MB/s".
- Check > "Check a Drive by Its Checksum List…" (DigiChecksumListCheck in DigiChecksum.swift, tested):
  reads every file in a backup's Checksums.xxh64 back from the drive, no session needed; alert with
  match / missing / different counts and Open Report; "<date> Drive Check.txt" in _StudioSession_Reports.

### 1.29 (Nov 8; independent-check session)
Background: Jeff ran independent checks (Apple's own diff -rq + cmp) on two Macs. Nov 5 LIG_GO
(256 GB) and Nov 6 Foundayo_Stills both came back clean: only .DS_Store, the manifest, the archive
and the reports folder differed, plus .cosessiondb (changes whenever Capture One is open). Empty
folders ARE copied (inventory.directories). So the engine is trusted file-for-file; 1.29 is fixes
and the top-tabs layout.

- Skip busy files instead of aborting (DigiStreamEngine): a source file whose size or date stamp
  moved mid-backup (Capture One / tether still writing it) was throwing and ending the WHOLE drive's
  backup. This was the "a file and a date stamp" error Jeff hit, which also seemed to need a quit +
  restart. Now checkSourceUnchanged throws a distinct `SourceChanged`; the copy lane, commit
  (commitOrSkip) and the verify-pass repair all catch it and SKIP that one file, keep going, and keep
  totals honest so the bar still reaches 100%. SyncProgress.skippedFiles; skippedThisRun -> report.
  The safety is unchanged: a changing file is still never copied. Recheck tolerance now matches the
  planner's 2 s (DigiStreamEngine.toleranceSkips, unit-tested). Drive card shows an amber "N files
  were still being written and were skipped. Run Back Up again…"; counts line adds "N skipped";
  report gets a "STILL BEING WRITTEN, SKIPPED THIS RUN" section with the list. New smoke test feeds a
  stale snapshot so one file is guaranteed to skip. NOTE: "Up to date" status string is kept so the
  done-logic (sound, auto-check, schedule result) still fires; skips are surfaced separately.
- Clear report history (DigiBackupReport.reportInfo / clearReports in DigiChecksum): deletes only the
  .txt reports in _StudioSession_Reports, never Checksums.xxh64 (incrementals + drive check need it).
  Drive card: "Reports: N saved … · Clear History…" (NSAlert, Cancel default, destructive Clear).
  WrapModel.reportInfo filled in the same detached pass as archiveInfo; confirmClearReports().
- Job Report folder thumbnail from the Capture One PREVIEW, not the raw (Jeff: raws can be unexposed/
  unedited). DigiCaptureOnePreview (in JobReport.swift): finds the sibling CaptureOne/Cache/Proxies
  <rawname>*.cop (then Thumbnails *.cot), decodes via ImageIO, else scans for the embedded JPEG
  (FFD8..FFD9). Falls back to the raw's embedded preview, so it's never worse than before. UNVERIFIED
  on Jeff's Capture One 16.9 .cop format: if a thumbnail still looks like the flat raw, get a sample
  .cop and tune the decoder.
- Top tabs for Studio Session (ShellGrip rewritten): tabs across the top instead of the slide-out
  sidebar (Jeff's request + approved mockup). Icon + two-word names stacked on two lines; NO shortcut
  numbers on the tabs (Command-1..8 still work via the menu). Backups tab carries a live status light
  (green/amber/red); a thin progress strip appears under the tabs while a backup runs, so the backup
  is never out of sight (replaces the old always-on sidebar panel). digiArrange is now horizontal for
  Grip; DigiAddToolMenu at the end adds hidden tools back. Sidebar collapse (Ctrl-Cmd-S) is gone.
  DigiNavStyle.sidebar enum case kept (routing/marks unchanged). Tour navBody rewritten for tabs.
- Studio Session tool names changed (Brand.swift BRAND_GRIP toolNames): Home, Backups, Selects Report,
  Export Check, Folder Maker, Job Report, Contact Sheets, Folder Checker, Metadata(hidden). Indices and
  Cmd-numbers unchanged; only display names.
- No new Swift files; no build.command / test-list changes. Not compiled here (no Swift toolchain in
  the cloud box); Jeff builds on his Mac. Build: cd "$HOME/Downloads/DigiFour_1_29" && bash build_all.command

### 1.30 (Nov 8; found during the live skip stress test)
Context: stress test on StressTest (218 GB, Full verify, hammered busy_big.dat). The big backup
ran flawlessly and flat (~700 then ~590 MB/s once the T7 cache filled), top-tabs UI worked, but
NO skip ever showed. Diagnosis: busy_big.dat was not on the T7 and skippedFiles was 0, i.e. the
hammer created it a moment AFTER the backup's snapshot, so it was never in the plan. The fix was
never exercised, not broken. BUT the investigation surfaced a real weakness, fixed here:
- Tighter source-change detection (DigiStreamEngine.sourceMoved, was toleranceSkips): the pre-copy
  check now treats ANY real change as a skip (size differs, or mtime differs by >1 ms), instead of
  the 2 s window 1.29 used. The 2 s window let a file changing within 2 s of the snapshot slip
  through on a quick backup, which is exactly the Capture One session-db case. The pre-copy check
  compares the SAME file at two moments, so it should be near-exact; the 1 ms margin only absorbs
  precision noise between contentModificationDate (snapshot) and .modificationDate (copy check).
  Tests updated (near-exact cases). The planner's own 2 s tolerance (source vs last backup) is
  unchanged and correct for its purpose.
- Home "NEXT" card now says "Verifying: N%" / "Verifying <source>…" during the read-back pass
  (matches the Backups tab), via DigiBackupSnapshot.verifying (all working drives in verify). It also
  names the backup SOURCE (model.syncSource ?? root), not whatever session Home is showing (Jeff saw
  "Copying testing" while backing up StressTest). Grip's top running-strip says "Verifying" too.
- Clean skip test: start the hammer FIRST (busy_big.dat exists and is changing), THEN Start Backup,
  so the file is in the snapshot. With 1.30's near-exact check it will skip even on a quick backup.
- Not compiled here (no Swift toolchain); Jeff builds on his Mac.
  Build: cd "$HOME/Downloads/DigiFour_1_30" && bash build_all.command

### 1.31 (Nov 8)
- Job Report thumbnail: REVERTED the 1.29 Capture One preview path. On Jeff's Capture One 16.9 the
  .cop proxy decoded to black frames with a tiny sliver (the proxy is not a clean JPEG, and the bad
  decode returned a non-nil CGImage so the raw fallback never fired). Back to the raw's embedded
  preview (reliable 1.28 behavior). DigiCaptureOnePreview is left in JobReport.swift but UNUSED,
  ready for a proper, validated decoder once a real .cop sample is analyzed. Rule for the rework:
  only use the preview if it decodes to a sane image, else fall back to the raw.
- Build: cd "$HOME/Downloads/DigiFour_1_31" && bash build_all.command

### 1.32 (Nov 8; graded Job Report thumbnails via Output)
Finding: Capture One 16.9 proxies (.cop) are progressive JPEG XL. macOS itself can't decode them
(Finder Quick Look of the same bytes renamed .jxl shows the identical black-frame-with-sliver), so
there is NO system route to the graded preview from the proxy. Dropped that idea for good; removed
the dead DigiCaptureOnePreview enum from JobReport.swift.
- Instead: Job Report folder thumbnail now PREFERS a graded JPEG from the session's Output folder,
  matched by lowercased filename stem, and falls back to the raw's embedded preview when a frame
  isn't exported yet. Jeff's QuickProof writes graded JPEGs (the 3840px preview, fast) into Output
  with the SAME base name as the raw, so a normal shoot→cull→QuickProof→report gives graded thumbs
  with zero extra steps and no JXL decoding. Index built once per report (proofByStem, walks
  root/Output for jpg/jpeg/heic/heif/png/tif/tiff). Not in a view body, so the walk is fine.
- Build: cd "$HOME/Downloads/DigiFour_1_32" && bash build_all.command

### 1.33 (Nov 8; cable-pull test → notify loudly on failure)
Cable-pull test (yanked T7 mid-backup): PASSED the safety half. Clean error on the .shootwrap-*.tmp
TEMP (never a real file), backup stopped, no corruption. But it was SILENT (no popup, no Dock bounce),
which Jeff rightly flagged. Found: notifyBackupResult already posted a UNUserNotification, but
DigiSuite.backupNotifications defaults OFF and auth was only requested when the toggle was turned on,
and there was no Dock bounce at all.
- Fix: a failed/interrupted backup now ALWAYS bounces the Dock (NSApp.requestUserAttention(.criticalRequest))
  and posts a notification, regardless of the toggle. A clean completion notifies only when the toggle
  is on (so a 2-min schedule doesn't nag). Notification auth requested at launch (applicationDidFinishLaunching)
  so the banner can show even when the user is in Capture One. Menu toggle relabeled "Notify When Backups
  Succeed" with a help note that problems always alert.
- Friendlier disconnect message (DigiStreamEngine.posixFailure): ENXIO/EIO/ENODEV → "“<drive>” was
  disconnected during the backup. Reconnect it and run Back Up again." instead of raw "Device not configured".
- Live drive watch (WrapModel.startDriveWatchIfNeeded): observes NSWorkspace didMount/didUnmount/didRenameVolume
  to refreshDriveStatus, so a reconnected drive's card updates immediately instead of staying "Not connected"
  from the failed run. Started from the dashboard onAppear.
- Deduped a double `import UserNotifications`.
- Recovery half of the cable-pull test (plug back in → Start Backup resumes incrementally; find no leftover
  .shootwrap-*.tmp) still to be confirmed by Jeff.
- Build: cd "$HOME/Downloads/DigiFour_1_33" && bash build_all.command

### 1.34 (Nov 8; orphan temp sweep — found by the cable-pull test)
The cable-pull test left an orphaned temp on the drive: find turned up
/Volumes/WolkPhoto2TB/StressTest/Capture/.shootwrap-74977F72-...tmp (a different UUID than the one
that errored, so 2+ small-file temps were in flight when the drive dropped). Later runs didn't clean
it because each run only tracks its OWN temps. These temps are F_PREALLOCATE'd to full file size, so
orphans waste real space over many interrupted backups. (Includes everything in 1.33; use 1.34, skip 1.33.)
- Fix: DigiStreamEngine.removeOrphanTemps(in:) walks the destination and deletes any .shootwrap-*.tmp,
  skipping the archive/reports subtrees (toolFolderNames). Called at the very start of
  DigiStreamEngine.sync, where the caller already holds the destination lock, so no active run owns a
  temp there (only pre-existing orphans are removed, never this run's). Enumerator does NOT skip hidden
  files (temps are dot-prefixed). New smoke test: drop a fake .shootwrap-*.tmp, sweep, assert it's gone
  and a real sibling + the archive are untouched.
- Build: cd "$HOME/Downloads/DigiFour_1_34" && bash build_all.command

### 1.35 (Nov 8; failure alert is now a must-click dialog)
Jeff: a backup failure must be a modal dialog you acknowledge, NOT a top-right banner you can swipe
away. Changed notifyBackupResult: on a problem it now shows a critical NSAlert (OK button) via
DispatchQueue.main.async + runModal, plus the Dock bounce (so a backgrounded app pulls you to the
waiting dialog). Guard `failureDialogShowing` stops a 2-min schedule from stacking dialogs (while one
is up, later failures don't queue another; the async+runModal also serializes on the main queue).
Deliberately does NOT NSApp.activate/steal focus, so a failure mid-tether in Capture One doesn't grab
focus and risk a missed shot; the persistent Dock bounce brings the user over and the dialog waits.
Success banner unchanged (opt-in "Notify When Backups Succeed").
- Test: fail a backup while on the app → dialog appears, must click OK. Fail while in another app →
  Dock bounces; clicking back shows the dialog.
- Build: cd "$HOME/Downloads/DigiFour_1_35" && bash build_all.command

### Nov 9 test day (1.35, jury duty; StudioSession_TestKit + engine probe)
Kit: StudioSession_TestKit.zip (make_test_sets, make_test_drives, verify_backup = independent diff/stat check,
tether_sim, hammer, churn, fill_drive). Test drives are disk images on WolkPhoto1TB_A (2 TB APFS):
SSTest_APFS, SSTest_HFS, SSTest_Tiny, SSTest_XFAT (exFAT; volume names max 11 chars, hdiutil -fs ExFAT
fails, made via diskutil eraseDisk). Capture One open for every test. Drives today: WolkPhoto1TB_A
(2 TB) and WolkPhoto1TB_B (1 TB), both APFS, 10 Gb/s.
- PASS: A1/A2 failure dialog + Dock bounce, Capture One keeps focus. A4 crash: orphan temp swept, 700/700 identical.
- PASS: B shooting day. SSTest_Shoot 128.55 GB / 18,171 files to both drives at once: 6m35s (681 MB/s copy,
  3m24s verify) and 7m06s (540 MB/s, 3m07s verify), Capture One open + fake tether. Scheduled 2-min runs
  2-3 s each; .cosessiondb and busy_big.dat (same-size rewrite) skipped while busy, caught next run;
  20 Capture One renames detected as renames. Final verify_backup PASS on both (18,465 files).
- PASS (data) / FAIL (record-keeping): C1 yank during verify: rerun says "Up to date" with 173 files never
  read back AND no Checksums.xxh64 written (report is written at the END of a run; drive gone; next run
  has nothing new so writes nothing). C2/C3 Stop: rerun leaves unverified files too, but the list exists,
  so Folder Checker > Check a Drive by Its Checksum List shows 700/700.
- D1-D3 PASS with notes: hidden files are skipped by design (BackupFilter.includeHidden false; toggle in
  each drive's settings); NFC accented names are stored as NFD on the backup (content identical, no recopy).
- D4 FAIL -> fixed in 1.36 (below).
- E2 PASS on 1.36: Big to WolkPhoto1TB_A (APFS) + real exFAT drive at once, exFAT cable pulled at ~33%:
  A finished alone (verified), dialog "Partial: 1 up to date, 1 failed". After reconnect: exFAT copied
  135, 565 unchanged (those 565 never read back: same as open item 1); verify_backup PASS on both
  (700/700), no temps. Odd: exFAT yank shows the raw error ".shootwrap-....tmp couldn't be opened because
  there is no such file" instead of the friendly "was disconnected" (posixFailure only maps ENXIO/EIO/
  ENODEV; this one comes from FileManager/Cocoa). Odd: clicking to choose the exFAT drive (Use This Drive /
  Add Folder... New Folder on exFAT) sometimes didn't register; not investigated.
- D6 (1.36): symlink OK (not copied/followed). UNREADABLE file (chmod 000): whole backup fails, 0 of 2
  copied ("Could not copy ...: Permission denied"). FINDER-LOCKED file (uchg): copyMetadata copies the
  uchg flag onto the temp, setAttributes(mtime) then fails ("You don't have permission to save the file
  .shootwrap-....tmp"), whole backup fails, and the locked temp is left behind; removeOrphanTemps can't
  delete it, so one more locked temp piles up per run (2 after 2 runs).
Open for 1.37+ (none built yet):
0. DONE in 1.37: unreadable / Finder-locked source files no longer block the backup (see 1.37).
1. Read-back/record after an interrupted run: write each checksum to the list as files commit (not at the
   end), and have the next run finish any read-back the previous run didn't (C1/C2/C3).
2. After a crash, the app forgets source/destinations and says nothing about the interrupted backup (A4).
3. Failure dialog should name the drive and reason; no "needs attention" dialog for the person's own Stop;
   "1 errors" plural; free space on the card doesn't refresh after a run.
4. Report: a SKIPPED file is described as "copied before checksums were turned on" (and "1 files",
   and "Compare > Deep Verify" should be Folder Checker).
5. Archive keeps a full .cosessiondb (~27 MB) every run Capture One changes it; consider keeping fewer.
6. Kit: tether_sim writes its log inside the session folder (move it out); verify_backup should ignore
   .fseventsd/.Trashes when the backup is a volume root.

### 1.36 (Nov 9; exFAT fix, found and isolated on test day)
Symptom (D4): any backup to exFAT stopped on the first large file: "Copied size differs from the source".
Isolated with an engine probe built from the real 1.35 engine files (app untouched) on SSTest_XFAT:
- One large file alone: fine. Large file + the small-file lane writing into the same folder: the temp
  reads back 0 bytes (copy=0). Needs F_NOCACHE + F_PREALLOCATE + concurrency together.
- Removing only F_PREALLOCATE: right size, but full EdgeCases ended with WRONG CONTENTS in
  16MiB_exact.bin and 8MiB_exact_RENAMED.bin (same size and date!). Full verify caught one; Quick or Off
  would have been silent.
- Removing only F_NOCACHE (cached writes): 2,065/2,065 copied and verified, verify_backup identical
  (except the known hidden-file / NFD-name lines). Copying everything via copyfile also passed (slower).
Fix: DigiStreamEngine.filesystemType(root) (statfs f_fstypename) once per backup; on "exfat" or "msdos"
(prefersCachedWrites) copyLarge(uncached: false) skips F_NOCACHE (copy lane and repair). Space
reservation, small-file lane, read-back (uncached reads) unchanged. APFS/HFS+ path byte-identical to 1.35.
Engine note says "exFAT/FAT drive: cached writes". New smoke test (v1.36): the rule, the volume's
filesystem type, and a cached-write copyLarge round trip.
Confirmed Nov 9 on 1.36: SSTest_XFAT disk image (2,065 copied + verified, verify_backup clean) AND a real
exFAT drive (WolkPhoto1TB_B erased as ExFAT "exfat", USB 10 Gb/s): EdgeCases 2,065 copied + verified,
copy 6 s at 572 MB/s, verify 3 s, verify_backup clean (only hidden-file / NFD-name lines); second run
0 copied / 2,065 unchanged (incrementals work on real exFAT). One run each;
not a speed comparison.
- Build: cd "$HOME/Downloads/DigiFour_1_36" && bash build_all.command

### 1.37 (Nov 9; one odd file no longer blocks a backup; found in D6)
Before: one unreadable file (no read permission) or one Finder-locked file (uchg) ended the WHOLE
drive's backup, every run; the locked case also left an undeletable locked temp per run.
- Unreadable: the copy lane checks access(R_OK) right after the busy check. Unreadable -> LaneResult
  .problem(entry, lane, reason): skipped, totals adjusted, SyncProgress.problemFiles += 1, listed with
  its reason. Never fatal.
- Locked: copyfile copies uchg onto the temp. commit() now unlocks the temp (unlockIfLocked) before
  setting the date and placing it, unlocks an existing locked backup copy before archiving/replacing
  it, then relocks: the new backup copy gets the original's flags back (so it is locked like the
  original), an archived older copy keeps its lock. Same unlock/relock in repair(), rename moves and
  archive-removed moves. If a lock can't be cleared, the file becomes a SourceProblem (skipped +
  flagged) instead of failing the run.
- Temps: removeTemp() clears flags before deleting (all temp clean-up paths); removeOrphanTemps clears
  flags too, so locked temps left by 1.36 and earlier are swept on the next run.
- Card: red "N file(s) couldn't be backed up and are NOT on this drive (no permission to read, or
  locked). Everything else is backed up. See the report..." and "N not backed up" in the counts line.
  Status stays "Up to date" for what WAS backed up (done-logic, sounds and schedule unchanged); no
  dialog for problem files (a 2-min schedule would re-alert every run). Open question for Jeff: alert?
- Report: "Result: COMPLETE EXCEPT N FILES THAT COULDN'T BE BACKED UP" and a "COULDN'T BE BACKED UP"
  section (file: reason, how to fix). Also fixed: skipped and problem files are no longer counted as
  "copied before checksums were turned on" (open item 4); the line now says "Folder Checker > Deep
  Verify" and pluralizes. Card: "1 error" (was "1 errors").
- Smoke test (v1.37): unreadable file flagged + skipped while the rest copies, locked small + large
  files backed up byte for byte and kept locked, changed locked original replaces + archives the
  locked copy, locked orphan temp swept, report wording.
Not compiled here (no Swift toolchain). Re-run D6 (Tricky B and C) on 1.37 to confirm in the app.
- Build: cd "$HOME/Downloads/DigiFour_1_37" && bash build_all.command

### 1.38 (Nov 9; smoke tests on GitHub's Macs)
No app or engine changes (same code as 1.37). Adds .github/workflows/smoke-tests.yml: on every push
(and by hand from the Actions tab) a GitHub-hosted macos-15 runner runs RUN_FAST_BACKUP_TESTS.command,
so a version's smoke tests can pass before Jeff builds it. publish_github.command already copies the
whole version folder (including .github) into ~/Developer/StudioSession and pushes, so pushing 1.38
turns it on. Jeff is on GitHub Free: macOS minutes count 10x against 2,000/month (about 200 Mac
minutes). Run time per push not measured yet; estimate 3-5 min. Without a payment method on file,
usage simply stops at the quota. Still: ask Jeff before every push.
Drive tests (yanks, exFAT hardware, Capture One) can't run there; those stay on Jeff's Mac.

