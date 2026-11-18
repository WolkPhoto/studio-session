#!/bin/bash
# v1.46.7: backs up onto real APFS, Mac OS Extended, exFAT and FAT volumes.
# Makes four small disk images in a temporary folder, mounts them there (hidden from
# Finder, nothing in /Volumes), runs Tests/DriveFormatTests.swift, then unmounts and
# removes them. Never touches a real drive. About 1 GB of free space needed while it runs.
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Drive-format checks require macOS and Xcode Command Line Tools." >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/digisuite-drive-formats.XXXXXX")"
devices=()
cleanup() {
  for device in "${devices[@]+"${devices[@]}"}"; do
    hdiutil detach -quiet "$device" 2>/dev/null || hdiutil detach -quiet -force "$device" 2>/dev/null || true
  done
  rm -r "$work"
}
trap cleanup EXIT

echo "Building the drive-format tests..."
xcrun swiftc -target arm64-apple-macosx14.0 -parse-as-library -O -framework Foundation \
  FastBackupCore.swift DriveCheck.swift DigiStreamEngine.swift DigiChecksum.swift DigiArchive.swift \
  FolderPlanCore.swift MetadataSidecar.swift Tests/DriveFormatTests.swift \
  -o "$work/DriveFormatTests"

volumes=()
for format in APFS HFS+ ExFAT MS-DOS; do
  name="SSTEST$RANDOM"
  image="$work/$name.dmg"
  echo "Making a 200 MB $format test volume..."
  hdiutil create -quiet -size 200m -fs "$format" -volname "$name" "$image"
  attached="$(hdiutil attach -nobrowse -noautoopen -mountrandom "$work" "$image")"
  devices+=("$(echo "$attached" | head -1 | awk '{print $1}')")
  mount="$(echo "$attached" | awk -F'\t' 'NF >= 3 && $3 != "" {print $3}' | tail -1 | sed 's/[[:space:]]*$//')"
  [ -d "$mount" ] || { echo "Couldn't mount the $format test volume." >&2; exit 1; }
  volumes+=("$mount")
done

"$work/DriveFormatTests" "${volumes[@]}"
echo "Drive-format checks passed: APFS, Mac OS Extended, exFAT, FAT."
