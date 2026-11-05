# Four apps, one engine

This folder builds four separate Mac apps. They do exactly the same work with the
same Digi Stream backup engine and the same safety rules. What changes is the look,
the feel and how you get around.

| App | How you get around | Feel |
|---|---|---|
| **Studio Session** (was Grip) | Sidebar on the left. Command-1 to Command-9 jump to tools. Backups always visible at the bottom of the sidebar. | Dark studio graphite, tungsten orange |
| **Wrap** | Color checker patches across the top open every tool. | Photo-native: 18% grey and color checker patches |
| **Proof** | The shoot day as sections across the top: Dashboard, Folders, Back Up, Verify, Selects, Deliver, Wrap Up. | Light, Swiss, calm |
| **Tally** | Lives in the menu bar with a tally light. Click it to back up without opening a window. | Quiet, rounded, a red tally light |

Every app opens with a one-minute tour the first time. Skip it any time; bring it back
from the Help menu. Each app has its own settings, so they can all be installed side by side.

## Build

Unzip into Downloads, then in Terminal:

```bash
cd "$HOME/Downloads/DigiFour_1_27" && bash build_all.command
```

That runs the backup tests once, builds all four, and opens them. To build one:

```bash
cd "$HOME/Downloads/DigiFour_1_27" && bash build_grip.command
cd "$HOME/Downloads/DigiFour_1_27" && bash build_wrap.command
cd "$HOME/Downloads/DigiFour_1_27" && bash build_proof.command
cd "$HOME/Downloads/DigiFour_1_27" && bash build_tally.command
```

The classic Digi Suite still builds from the same folder: `bash build.command`.

## Good to know

- Only one app at a time can back up into the same backup folder. If two apps try,
  the second one skips that drive and says "In use by another app". Nothing is overwritten.
- After its tour, each app offers to install itself in Applications and the Dock.
  Click Not Now while you're comparing them.
- Quit any running Digi Suite backup before building, as always.

## Five-minute test for each app

1. It opens with its own name and icon in the Dock, and the tour card appears bottom right.
2. Click through the tour. Try one "Show Me" button: the screen behind the card should change.
3. The big button says "Open your session". Click it and pick a session folder.
4. The big button now asks for a drive. Pick your backup drive in the backups tool.
5. Click "Back Up Now". The app's status display shows progress; Pause and Stop work.
6. Open the compare tool (Check, Compare or Verify, depending on the app) and confirm it scans on its own.
7. The question mark in the bottom right corner brings the tour back.

App-specific:
- Studio Session: Command-1 to Command-9 jump between tools.
- Wrap: the color patches open every tool.
- Proof: Dashboard and Back Up get a check mark once done.
- Tally: the menu bar icon opens a panel with your drives and a Back Up button.

## Release builds (signed, notarized DMGs)

Double-click `release.command` in this folder (or `bash release.command`). It builds Studio
Session and Tally, signs them with your Developer ID, has Apple notarize them, staples the
ticket, and puts `Studio Session <version>.dmg` and `Tally <version>.dmg` in
~/Desktop/Digi Releases. The first run walks you through the one-time notary login.
Needs the paid Apple Developer Program and a "Developer ID Application" certificate
(Xcode > Settings > Accounts > Manage Certificates > +).

## Studio Session 1.25

Only Studio Session is built now (`build_all.command`, `release.command`).

- **Verified backups:** on by default (Backups > Configure schedule and archive options).
  Each drive gets `_StudioSession_Reports` with a backup report and `Checksums.xxh64`.
- **Go easy while Capture One is open:** on by default, same place.
- **Archive:** each drive card shows its size with **Clear…** (asks first). Automatic
  clean-up of the oldest copies below a free-space limit is off until you turn it on.
- **Check for Updates:** Studio Session menu. Needs `UPDATE_REPO.txt` (owner/repo),
  which `publish_github.command` fills in on its first run.
- **GitHub:** double-click `publish_github.command`. First run signs you in, asks for a
  name and private/public, and creates the repository. Later runs push the new version.
  `release.command` then offers to publish the DMG as a GitHub release.
