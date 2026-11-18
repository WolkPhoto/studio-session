#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Building Digi Suite from: $PWD"
grep -q 'DigiQuitDelegate' ShootWrap.swift || { echo "Quit guard missing"; exit 1; }
grep -q 'Text("Backup progress")' ShootWrap.swift || { echo "Approved Backup UI missing"; exit 1; }
grep -q 'contentsOfDirectory(at: directory.url' FolderCompare.swift || { echo "Explicit scan fix missing"; exit 1; }
grep -q 'sourceSnapshot.directories' ShootWrap.swift || { echo "Empty-directory sync fix missing"; exit 1; }
grep -q 'DeepVerifyTracker' FolderCompare.swift || { echo "Deep Verify ETA missing"; exit 1; }
bash build.command
