# Digi Suite: project notes for Claude Code

Owner: Jeff, working photographer / digital tech (Capture One). Native macOS
SwiftUI app, Apple Silicon, macOS 14+. Bundle ID `com.digitools.app`.
Current version: 1.25.0 (folder `DigiFour_1_25`). One codebase; since 1.25 only Studio Session (BRAND_GRIP) is built and released. Wrap, Proof, Tally and classic code remain, unused.

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
- Every delivered version gets the exact Terminal build command for its
  folder name, e.g. `cd "$HOME/Downloads/<Folder>" && bash build.command`.
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
