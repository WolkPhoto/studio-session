Capture One session detection (experimental)
- Starts on Digi Suite launch and checks every 12 seconds while Capture One is running.
- Attempts to read the current document path via Capture One AppleScript, then falls back to the first variant file path.
- Requires a .cosessiondb file in the discovered folder before offering it.
- Capture One may request macOS Automation permission.
- No change without confirmation; dismissed sessions are ignored for the rest of this app launch.
- Detect Session on Dashboard retries explicitly.
- Active backup/scanning operations defer session switch.
- No background backup starts from detection.
- Capture One scripting support varies by version. If it cannot expose a path, use Open Session.
