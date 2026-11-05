# Studio Session

Backups and shoot-day tools for digital techs on macOS (Apple Silicon, macOS 14+).

- **Verified backups** to up to four drives at once. Every copy is checked with
  xxHash64 (the original is hashed as it's read, the copy is read back from the
  drive) and each drive gets a backup report and an `xxhsum`-compatible checksum
  list in `_StudioSession_Reports`.
- **Capture One friendly**: finds the open session, and backups step aside on the
  disk while Capture One is open.
- **Archive**: earlier versions of changed or removed files are kept in
  `_StudioSession_Archive` on each drive, with size, Clear, and optional automatic
  clean-up when a drive runs low.
- **Folders** from shot lists (paste, spreadsheet, or a picture of a list),
  **Compare** with Deep Verify, **Contact Sheets**, **Exports** check, **Selects**,
  and a **Report**.

## Build

```bash
bash build_all.command      # tests, then builds and opens Studio Session.app
bash release.command        # signed, notarized DMG (Developer ID required)
bash publish_github.command # push this version to GitHub
```

Project notes for contributors (and Claude) are in `CLAUDE.md`.
