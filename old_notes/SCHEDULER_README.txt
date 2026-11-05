Digi Suite: Scheduled Incremental Backup (test source)

Backups tab: enable automatic backups and choose an interval in minutes (1-1440).
The schedule is saved in UserDefaults and runs only while the app is open.
Each destination is handled independently. A missing source skips the cycle.
Missing destination paths are skipped, never created by the scheduler.
Existing staged SHA-256 verification, archive policies and backup filters are reused.
A running manual or scheduled sync prevents overlapping scheduled cycles.
Results are displayed per destination in the Backups tab.

IMPORTANT TEST NOTES
- macOS compilation has NOT been performed in this environment.
- Verify expected volume identity for drives that mount under /Volumes before relying on unattended operation.
- Test unplugged destinations, reconnection, source unavailability and a busy backup.
- This is an in-app timer, not a launchd background service.
