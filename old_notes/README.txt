Digi Suite 13: Continuous Native Copy Queue

Run: bash build.command
Requires macOS 14+, Apple Silicon and Xcode Command Line Tools.
Normal backups use native macOS file copies without SHA-256 verification.
Incremental runs copy new or changed files based on size and modification time.
Unchanged files are skipped. Use Folder Compare > Deep Verify for content checks.
Two native copies run per destination, refilling after each completed commit.
See CONTINUOUS_COPY_13_NOTES.md for the change, measurements and test instructions.
The build runs fast-backup fixture checks on the Mac before compiling the app.
The optional legacy speed benchmark still tests the older version 10 engine.
Older .shootwrap workspaces remain loadable; new workspaces use .digitools.
This source has not been compiled or run on macOS in the preparation environment.
