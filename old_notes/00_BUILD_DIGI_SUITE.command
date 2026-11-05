#!/bin/bash
# Double-click in Finder to build and launch Digi Suite.
set -o pipefail
cd "$(dirname "$0")" || exit 1
printf '\n=== Digi Suite: Build & Run ===\nProject: %s\n\n' "$PWD"
if [[ ! -f build.command ]]; then
  echo 'ERROR: build.command was not found in this folder.'
  echo 'Keep this launcher next to the project build.command file.'
  read -r -p 'Press Return to close... ' _
  exit 1
fi
if bash ./build.command; then
  APP="$(find "$PWD" -maxdepth 3 -type d -name 'Digi Suite.app' -print -quit)"
  if [[ -n "$APP" ]]; then
    echo "Build finished. Opening: $APP"
    open "$APP"
  else
    echo 'Build finished, but Digi Suite.app was not found automatically.'
  fi
else
  echo 'BUILD FAILED. See errors above.'
fi
printf '\n'
read -r -p 'Press Return to close this window... ' _
