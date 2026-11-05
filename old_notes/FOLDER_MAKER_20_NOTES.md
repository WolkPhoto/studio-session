# Digi Suite 20: Folder Maker rebuilt

```bash
cd "$HOME/Downloads/DigiSuite_20_6" && bash build.command
```

Built for the real job: a client sends a spreadsheet, an email or a shot list,
and every shot needs a folder.

## Input
- **Import File**: Excel (.xlsx/.xlsm), CSV/TSV, email (.eml), PDF, Word
  (.doc/.docx), RTF, HTML, JSON and text. Drop a file anywhere on Folder
  Maker, or use Choose File. Numbers files: export to CSV or Excel first.
- **Spreadsheets** show as a grid. Click the columns to use, in order.
  Choose "One folder name" (columns joined: `01 - Red Dress`, `01_Red Dress`
  or `01 Red Dress`) or "Nested folders" (each column is a level). Blank rows
  are skipped. Pick the sheet in multi-sheet workbooks.
- **Paste & Interpret**: paste an email or list (or use Paste from
  Clipboard, or drop text). Smart mode reads bullet lists, "Shot 1: ..." lines
  under a heading such as "Shot list for Tuesday:", "Folder: description"
  bullets and explicit requests, and skips greetings, signatures and
  "don't create" lines. Lines it is unsure about are listed with an Add
  button. Smart off: every line becomes a folder.
- **Sequences** update the preview as you type. Typed ranges such as
  "Shot_01 through Shot_24" still work.

## Building the structure
- **Subfolders inside each folder** (for example `Selects, Output`), with
  saved presets.
- **Tokens**: `{session}` and `{date}` (yyyy_MM_dd) in any name.
- **Preview** shows each folder and its subfolders as a tree, marked New or
  Exists, with editable names. Names are made safe for macOS (a colon becomes
  " -") and listed under "Renamed for macOS"; duplicates and unusable names
  are listed under "Skipped".

## Destination
- Follows the open session: **Session**, **Capture** (default) or
  **Output**, or **Choose…** for anywhere else. Show in Finder after creating.
- Never overwrites: existing folders are left alone. Undo removes only the
  folders it created that are still empty.

## Under the hood
- The Python engine (engine.py, folder_bridge.py) is replaced by
  FolderPlanCore.swift. No Python or extra libraries are needed. The old
  engine needed an Excel library that was missing from the app, so Excel
  import did not work before this version.
- Headless tests cover names, sequences, email and shot-list reading, CSV,
  a generated Excel workbook, email decoding, and create/undo.

## 20.1
- Same as 20, with a test-file fix (a variable name was declared twice).
- 20.2: Folder Maker screen split into smaller views so the compiler can check it.
- 20.3: "Paste & Interpret" replaced by **Paste List** at Jeff's request (reading
  meaning out of emails needs AI). One folder per line, live preview, optional
  bullet/number removal and comma splitting, / for subfolders. Imported email,
  PDF and Word text lands in the list for editing. Switching tabs shows that
  tab's list. The smart reader stays in FolderPlanCore (unused) for later.
- 20.4: Import simplified at Jeff's request: click one column, each cell
  becomes a folder (multi-column combine/nest removed for now; the engine
  still supports it). Repeated names in the preview are marked Duplicate.
- 20.5: Repeated names are combined when a column or pasted list is read, so
  the preview count always matches "Create N Folders". The status line says
  how many repeats were combined. (Jeff: showing duplicates that would not be
  created was confusing.)
- 20.6: The selected Create In location (Session, Capture, Output or a chosen folder) is a filled blue button with a checkmark.
