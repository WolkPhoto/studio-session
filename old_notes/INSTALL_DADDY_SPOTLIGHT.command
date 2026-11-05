#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/Digi Suite.app"
if [ ! -d "$APP" ]; then
  echo "Digi Suite.app not found. Build the app first." >&2
  exit 1
fi
# A Finder alias is a real Spotlight-indexable file. This does not rename the app.
# Keep it in the user's Applications folder to avoid admin permission prompts.
ALIAS_DIR="$HOME/Applications"
mkdir -p "$ALIAS_DIR"
/usr/bin/osascript - "$APP" "$ALIAS_DIR" <<'APPLESCRIPT'
on run argv
  set appPath to item 1 of argv
  set destinationPath to item 2 of argv
  tell application "Finder"
    set appItem to POSIX file appPath as alias
    set targetFolder to POSIX file destinationPath as alias
    if exists item "Daddy Loves You" of targetFolder then
      delete item "Daddy Loves You" of targetFolder
    end if
    set shortcut to make new alias file at targetFolder to appItem with properties {name:"Daddy Loves You"}
  end tell
end run
APPLESCRIPT
/usr/bin/mdimport "$ALIAS_DIR/Daddy Loves You" 2>/dev/null || true
printf '\nDaddy Easter egg installed in %s\n' "$ALIAS_DIR"
printf 'Search Spotlight for Daddy, then select Daddy Loves You. Spotlight may need time to index the alias.\n'
