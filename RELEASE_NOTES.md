Studio Session 1.25

- Every copy is verified: the original is checksummed (xxHash64) while it's read, the copy is read back from the drive and checked before it's kept. Each drive gets a backup report and a full checksum list in _StudioSession_Reports.
- Backups go easy on the disk while Capture One is open, and the app checks Capture One far less often.
- Archive: new copies go in _StudioSession_Archive. See how big it is on each drive, clear it (with a confirmation), or have the oldest copies cleared automatically when a drive runs low.
- Check for Updates in the Studio Session menu.
- Metadata is hidden for now.
