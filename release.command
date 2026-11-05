#!/bin/bash
# Builds Studio Session for sharing: signed with your Developer ID,
# notarized by Apple, stapled, and packed into DMGs on your Desktop in
# "Digi Releases". Double-click it in Finder, or run: bash release.command
# Nothing outside this folder and "Digi Releases" is touched.
set -uo pipefail
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-DigiNotary}"
OUT="$HOME/Desktop/Digi Releases"
VERSION="$(sed -nE 's/^VERSION="([^"]+)"/\1/p' build.command)"
LOG="$PWD/release_log.txt"
: > "$LOG"

stop() {
  echo ""
  echo "STOPPED: $1"
  echo "Details are in release_log.txt in this folder. Send it to Claude if this is unclear."
  exit 1
}

echo "=== Digi release $VERSION ==="

# 1. Developer ID certificate
ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Developer ID Application:[^"]+)".*/\1/p' | head -n 1)"
if [ -z "$ID" ]; then
  cat <<'MSG'

No "Developer ID Application" certificate on this Mac yet. One-time setup:
  1. You need the paid Apple Developer Program (developer.apple.com/programs).
  2. Open Xcode > Settings > Accounts, select your Apple ID and team,
     click Manage Certificates, click +, choose "Developer ID Application".
  3. Run this again.
MSG
  exit 1
fi
echo "Certificate: $ID"
TEAM="$(echo "$ID" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"

# 2. Notary login, saved once in your keychain
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat <<MSG

One-time notary login. You'll need:
  - your Apple ID email
  - an app-specific password: account.apple.com > Sign-In and Security >
    App-Specific Passwords > + (name it "Digi Notary")
  - your Team ID: $TEAM
macOS stores these in your keychain under the name "$PROFILE".

MSG
  xcrun notarytool store-credentials "$PROFILE" --team-id "$TEAM" || stop "The notary login wasn't saved."
fi

# 3. Tests once
echo "Running backup tests..."
bash ./RUN_FAST_BACKUP_TESTS.command >>"$LOG" 2>&1 || stop "Backup tests failed, nothing was built."

notarize() {  # $1 = file to submit
  echo "   Sending to Apple (usually 1 to 5 minutes)..."
  local result
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)"
  echo "$result" >>"$LOG"
  if ! echo "$result" | grep -q "status: Accepted"; then
    local sid
    sid="$(echo "$result" | sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' | head -n 1)"
    [ -n "$sid" ] && xcrun notarytool log "$sid" --keychain-profile "$PROFILE" >>"$LOG" 2>&1
    return 1
  fi
}

mkdir -p "$OUT"
release_one() {
  local key="$1" name="$2" bundle="$3"
  local app="$PWD/$name.app"
  local dmg="$OUT/$name $VERSION.dmg"
  echo ""
  echo "== $name =="
  echo "   Building..."
  echo "===== build $name =====" >>"$LOG"
  SKIP_TESTS=1 NO_OPEN=1 APP_NAME="$name" BUNDLE_ID="$bundle" BRAND="$key" \
    DIGI_SUITE_SIGN_IDENTITY="$ID" bash ./build.command >>"$LOG" 2>&1 || stop "$name didn't build."

  echo "   Signing..."
  codesign --force --options runtime --timestamp --entitlements DigiApp.entitlements \
    --sign "$ID" "$app" >>"$LOG" 2>&1 || stop "Signing $name failed."
  codesign --verify --strict --verbose=2 "$app" >>"$LOG" 2>&1 || stop "$name's signature didn't verify."

  local zip="$PWD/$name-notarize.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" || stop "Apple didn't accept $name. The reason is at the end of release_log.txt."
  rm -f "$zip"
  xcrun stapler staple "$app" >>"$LOG" 2>&1 || stop "Couldn't staple $name."

  echo "   Making the DMG..."
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/digidmg.XXXXXX")"
  ditto "$app" "$stage/$name.app"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -volname "$name" -srcfolder "$stage" -ov -format UDZO "$dmg" >>"$LOG" 2>&1 || stop "Couldn't make $name's DMG."
  rm -rf "$stage"
  codesign --force --timestamp --sign "$ID" "$dmg" >>"$LOG" 2>&1 || stop "Signing $name's DMG failed."
  notarize "$dmg" || stop "Apple didn't accept $name's DMG. The reason is at the end of release_log.txt."
  xcrun stapler staple "$dmg" >>"$LOG" 2>&1 || stop "Couldn't staple $name's DMG."

  echo "===== Gatekeeper check $name =====" >>"$LOG"
  if spctl -a -t open --context context:primary-signature -v "$dmg" >>"$LOG" 2>&1; then
    echo "   Done: $dmg"
  else
    stop "Gatekeeper didn't approve $name's DMG."
  fi
}

release_one grip "Studio Session" "com.digitools.grip"

# v1.25: publish to GitHub so Check for Updates finds it (optional).
UPDATE_REPO="$(tr -d '[:space:]' < UPDATE_REPO.txt 2>/dev/null || true)"
DMG="$OUT/Studio Session $VERSION.dmg"
if [ -n "$UPDATE_REPO" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo ""
  read -r -p "Publish $VERSION on GitHub ($UPDATE_REPO) so Check for Updates offers it? [y/N]: " PUBLISH
  if [ "${PUBLISH:-n}" = "y" ] || [ "${PUBLISH:-n}" = "Y" ]; then
    NOTES="RELEASE_NOTES.md"
    [ -f "$NOTES" ] || NOTES=""
    if [ -n "$NOTES" ]; then
      gh release create "v$VERSION" "$DMG" --repo "$UPDATE_REPO" --title "Studio Session $VERSION" --notes-file "$NOTES" >>"$LOG" 2>&1 \
        && echo "Published: https://github.com/$UPDATE_REPO/releases/tag/v$VERSION" \
        || echo "Couldn't publish on GitHub (details in release_log.txt). The DMG is still ready below."
    else
      gh release create "v$VERSION" "$DMG" --repo "$UPDATE_REPO" --title "Studio Session $VERSION" --notes "Studio Session $VERSION" >>"$LOG" 2>&1 \
        && echo "Published: https://github.com/$UPDATE_REPO/releases/tag/v$VERSION" \
        || echo "Couldn't publish on GitHub (details in release_log.txt). The DMG is still ready below."
    fi
  fi
fi

echo ""
echo "The DMG is signed, notarized and ready to share:"
echo "  $OUT"
open "$OUT"
