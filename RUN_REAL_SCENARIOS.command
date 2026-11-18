#!/bin/bash
# v1.46.7: Vanish, Grow and Stale at full size, with no clicking in Studio Session.
# Backs up the way Back Up Now does (same engine, drive lock, your Checking setting from
# Studio Session), while a watcher deletes files, grows the session database, or saves a
# file again mid-backup. Needs about 2 GB free.
#
#   bash RUN_REAL_SCENARIOS.command                 backs up to a temporary folder on this Mac (removed after)
#   bash RUN_REAL_SCENARIOS.command /Volumes/Drive  backs up to that drive, into a new folder
#                                                   "Studio Session scenario test <date>", left there for you
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "These checks require macOS and Xcode Command Line Tools." >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/digisuite-scenarios.XXXXXX")"
trap 'rm -r "$work"' EXIT

if [ $# -ge 1 ]; then
  [ -d "$1" ] || { echo "No such folder: $1" >&2; exit 1; }
  backup="$1/Studio Session scenario test $(date +%Y-%m-%d\ %H%M%S)"
  mkdir "$backup"
else
  backup="$work/Backups"
  mkdir "$backup"
fi

mode="$(defaults read com.digitools.grip DigiSuite.verifyMode 2>/dev/null || true)"
case "$mode" in full|quick|off) ;; *) mode="full" ;; esac

echo "Building the scenario tests..."
xcrun swiftc -target arm64-apple-macosx14.0 -parse-as-library -O -framework Foundation \
  FastBackupCore.swift DriveCheck.swift DigiStreamEngine.swift DigiChecksum.swift DigiArchive.swift \
  FolderPlanCore.swift MetadataSidecar.swift Tests/RealScenarioTests.swift \
  -o "$work/RealScenarioTests"
echo "Running Vanish, Grow and Stale (a few minutes)..."
"$work/RealScenarioTests" "$mode" "$backup"
echo "Scenario checks passed: Vanish, Grow, Stale."
if [ $# -ge 1 ]; then
  echo "The test backups are in: $backup"
  echo "Delete that folder when you're done with it."
fi
