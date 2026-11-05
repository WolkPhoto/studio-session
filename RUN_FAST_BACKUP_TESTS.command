#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Fast-backup checks require macOS and Xcode Command Line Tools." >&2
  exit 1
fi
fast_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/digisuite-fast-check.XXXXXX")"
trap 'rm -r "$fast_check_dir"' EXIT
xcrun swiftc -target arm64-apple-macosx14.0 -parse-as-library -O \
  -framework Foundation FastBackupCore.swift DriveCheck.swift DigiStreamEngine.swift DigiChecksum.swift DigiArchive.swift FolderPlanCore.swift Tests/FastBackupSmokeTests.swift Tests/FolderPlanSmokeTests.swift Tests/StreamEngineSmokeTests.swift \
  -o "$fast_check_dir/FastBackupSmokeTests"
"$fast_check_dir/FastBackupSmokeTests"
