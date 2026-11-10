Studio Session 1.45

New since 1.40:

**Metadata tab (new)**
- Fill in your IPTC info once (Creator, Copyright Notice, Provider, Headline, Job Identifier, Rights usage terms, Description, Keywords) and every new raw gets it as a sidecar .xmp next to it. Raw files are never changed.
- Capture One picks the sidecar up on its own when Preferences › Image › Auto Sync Sidecar XMP is set to Load. Your export recipes then put it in every JPEG and TIFF.
- Follows Capture One's capture folder as you switch it, and watches only when you click Start Watching.
- Same section names and labels as Capture One, including IPTC - Getty Images. Fill-ins: {year}, {date}, {session}, {filename}.
- Presets are .xmp files in Documents › Studio Session › Metadata Presets. Load any .xmp (for example one a client sends) with Load .xmp… or by dropping it on the tab.
- Anything you change in Capture One is kept unless you choose otherwise. "Apply to Existing Frames…" covers frames shot before you started.
- Optional: write the metadata into finished JPEG, TIFF and PNG files too (off unless you turn it on).

**Backups**
- A warning when a backup folder already holds a different session's backup, before anything is copied.
- Check for Updates now looks at the public download page, so future updates reach you automatically.

Nothing extra to install: the Metadata tab uses ExifTool by Phil Harvey (exiftool.org), which now comes built in.
