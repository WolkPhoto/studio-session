Studio Session 1.48

**1.48**
- New look: lighter midtone grays and a blue highlight color in place of orange. The app icon matches.
- Home: the Images, RAW files and Session size counts now update live while Home is open, adding each shot the moment it lands. One full recount runs about 2 seconds after shooting stops. Capture One's own cache and settings files are ignored. Selecting Home recounts.
- Folder Checker: matching rows now show green, so problems in yellow and red stand out. A new panel lists every missing or different file by folder and says why (not in a location, or size, date or contents differ). When everything matches it says so in green.
- Export Check: unprocessed files are laid out in columns across the window instead of one long list. Click, Shift-click or Command-click to select names; Command-C, Copy Selected or Copy All copies them one per line.
- Job Report: "Include a representative thumbnail for each folder" is on by default. New Clear History… button (your saved PDFs are not deleted).
- Backups: the time left says "Estimating…" until there's a fair read on the speed, instead of guessing from the first few seconds of tiny cache files. The top bar waits until every drive has an estimate.
- Fixed: removing a drive from the list while a backup was running still counted it, and could show "a backup needs attention" for a drive you'd removed.
- iPhone Remote is hidden for now and does not start; it returns in a later release. Pairings and settings are kept.

**1.47.8**
- Fixed: 1.47.7 crashed when opening iPhone Remote. The panel is now a fixed size and scrolls if its contents are taller.

**1.47.7**
- Fixed: the iPhone Remote panel cut off its top once it was turned on.
- The on/off switch is now a clear Off | On control.
- Each paired iPhone shows when it was paired and when it last connected. Pairing the same phone again replaces its old entry (for phones running the updated iPhone app).
- iPhone app: if iOS blocks it from looking on the Wi-Fi, the pairing screen says so and offers Open Settings, instead of looking forever.

**1.47.6**
- Fixed: iPhone Remote… could open out of sight when the main window was full screen. It now opens as a panel on the Studio Session window in front.
- New: a round iPhone button at the bottom right of the main window, next to the ? tour button, opens iPhone Remote. It's orange when iPhone Remote is on.

**1.47.5**
- New: iPhone Remote… is also in the Studio Session menu bar icon's menu.

**1.47.4**
- Fixed: with more than one Studio Session window open, the iPhone always showed the first one, so switching sessions in another window didn't reach the phone. The phone now shows the window you used last (a running backup always wins).
- iPhone app: it now checks the Mac as soon as it opens, not only after coming back from the background.

**1.47.3**
- Fixed: Studio Session menu > iPhone Remote… sometimes did nothing. It now opens its own small window from any Studio Session window, and that window is never reopened at launch.

**iPhone Remote (1.47)**
- New: Studio Session menu > iPhone Remote… lets a paired iPhone see the session, each drive's progress, speed and last backup, and start, pause or stop a backup. Off until you turn it on; pairing uses a six-digit code shown on the Mac.
- Works on the same Wi-Fi, and over cellular through Tailscale.
- The iPhone app (Studio Session Remote) is in the "iPhone Remote" folder; see its README.

New since 1.45:

**Backups you can trust under pressure (1.46.7)**
- A file that Capture One moves or deletes while a backup runs is now skipped and picked up next time. Before, it stopped that drive's backup with an error.
- A large file that grows while it's being copied (the session database, a raw still arriving) is skipped the same way, instead of failing the drive. The next backup copies it.
- A file saved again within 2 seconds with the same size is now noticed and copied on APFS and Mac OS Extended drives. Before, the backup could say "Up to date" and keep the older version. ExFAT and network drives keep the 2-second window for now.
- Backups to FAT (MS-DOS) formatted drives no longer copy every file again each time. The drive was resetting each copy's date as it was put in place, so nothing ever matched.
- If the last copies can't be confirmed on the drive at the end of a backup (for example the drive was unplugged), the drive now shows an error asking you to back up again, instead of "Up to date".
- After a backup with Checking set to Off, the drive's checksum list no longer keeps old checksums for files that backup replaced or removed, so Drive Check stops reporting those good copies as "different".

**Install and Metadata (1.46.7)**
- Installing to Applications now copies the new version first and only then moves the old one to the Trash. If the copy fails, the version you had stays in Applications.
- The Metadata tab can no longer freeze if ExifTool reports a lot of warnings, and a single ExifTool step that runs longer than 5 minutes is stopped.

**Safety (1.46)**
- If a large share of the session has disappeared from the source (or the folder is empty), Studio Session holds that drive and asks before moving those files to the archive. Nothing on the drive changes until you say Continue.
- Every backup is written all the way to the drive before it shows "Up to date", so unplugging right after doesn't lose the last files.

**Preview and backup screen (1.46.1 to 1.46.6)**
- Preview shows a card per drive, side by side: how much there is to copy and a bar of new, changed, gone and unchanged files. Each list opens to its files, grouped by folder, with Capture One's previews and settings folded into the photo folder they belong to.
- Preview sits right under Back Up Now and each drive's card fills in as soon as it's ready.
- The FROM card shows what's in the chosen folder: size, file count and the biggest kinds of files.
- Drive progress bars use each drive's exact color.
