DigiTools Contact Sheets integration test

Build on Apple Silicon macOS 14+: bash build.command

Seventh tab: Contact Sheets. Add JPEG/PNG/TIFF/HEIC and supported image folders,
reorder images, set rows/columns/page dimensions/margins, toggle filenames,
control compression and DPI, add header/footer and PDF metadata, preview pages,
and export multipage PDF.

The live PDF size estimate is based on up to 12 actual resampled JPEG samples,
then extrapolated to the full sheet. It is approximate, not a guaranteed cap.
Some camera RAW formats are not yet supported. PDF drawing and JPEG recompression
may affect exact file sizes.

Test with a few disposable images first. This code passed Swift parser checks,
but cannot be typechecked/compiled against macOS frameworks in this environment.
