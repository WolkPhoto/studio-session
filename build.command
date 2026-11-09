#!/bin/bash
# Builds one app from this folder. Run it through one of the
# "Build <App>.command" files, or directly for the classic Digi Suite.
#   APP_NAME   name in Finder and the Dock      (default: Digi Suite)
#   BUNDLE_ID  macOS identity, keeps settings apart (default: com.digitools.app)
#   BRAND      grip | wrap | proof | techcart | tally  (default: none = classic)
#   NO_OPEN=1  build without opening the app
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.40.0"
BUILD="50"
# v1.25: where Check for Updates looks (github.com/<owner>/<repo>/releases).
UPDATE_REPO="${UPDATE_REPO:-$(cat UPDATE_REPO.txt 2>/dev/null | tr -d '[:space:]' || true)}"
APP_NAME="${APP_NAME:-Digi Suite}"
BUNDLE_ID="${BUNDLE_ID:-com.digitools.app}"
BRAND="${BRAND:-}"

SWIFT_FLAGS=()
ICON_SOURCE="DigiSuiteIcon.png"
ICON_NAME="DigiSuite"
DOC_RANK="Owner"
TYPE_KEY="UTExportedTypeDeclarations"
if [ -n "$BRAND" ]; then
  FLAG="BRAND_$(echo "$BRAND" | tr '[:lower:]' '[:upper:]')"
  SWIFT_FLAGS=(-D "$FLAG")
  ICON_SOURCE="brand/$BRAND/icon.png"
  ICON_NAME="AppIcon"
  # The classic app owns the workspace file type; the others can open it.
  DOC_RANK="Alternate"
  TYPE_KEY="UTImportedTypeDeclarations"
fi

echo "=== Building $APP_NAME $VERSION ==="
if [ "${SKIP_TESTS:-}" != "1" ]; then
  bash ./RUN_FAST_BACKUP_TESTS.command
fi

APP="$PWD/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>$ICON_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Digi Suite Workspace</string>
<key>LSItemContentTypes</key><array><string>com.digitools.session</string></array>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>$DOC_RANK</string>
</dict></array>
<key>$TYPE_KEY</key><array><dict>
<key>UTTypeIdentifier</key><string>com.digitools.session</string>
<key>UTTypeDescription</key><string>Digi Suite Workspace</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>digitools</string><string>shootwrap</string></array><key>public.mime-type</key><string>application/json</string></dict>
</dict></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>DigiUpdateRepository</key><string>$UPDATE_REPO</string>
<key>NSAppleEventsUsageDescription</key><string>$APP_NAME reads which session Capture One has open.</string>
</dict></plist>
PLIST

xcrun swiftc -target arm64-apple-macosx14.0 -parse-as-library -O ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
  -framework SwiftUI -framework AppKit -framework Foundation -framework CryptoKit -framework ImageIO -framework PDFKit -framework Vision \
  FastBackupCore.swift DriveCheck.swift DigiStreamEngine.swift DigiChecksum.swift DigiArchive.swift FolderPlanCore.swift \
  Brand.swift BrandKit.swift BrandMarks.swift ShellGrip.swift ShellWrap.swift ShellProof.swift ShellCart.swift ShellTally.swift \
  ShootWrap.swift SessionComposition.swift FolderMaker.swift ContactSheets.swift JobReport.swift FolderCompare.swift \
  MetadataWatcher.swift DigiUpdater.swift BenchmarkCore.swift BackupBenchmark.swift Installer.swift DrivePermissions.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"
test -x "$APP/Contents/MacOS/$APP_NAME" || { echo "ERROR: $APP_NAME executable was not created" >&2; exit 1; }

cp DigiSuiteLogo.png "$APP/Contents/Resources/DigiSuiteLogo.png"
if [ -z "$BRAND" ]; then
  cp DigiSuite.icns "$APP/Contents/Resources/DigiSuite.icns"
else
  # Make the Dock icon from the 1024 px artwork with the tools built into macOS.
  ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/digiicon.XXXXXX")/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi
if [ -d vendor ]; then
  cp -R vendor "$APP/Contents/Resources/"
fi

# A persistent signing identity lets macOS keep drive-access permissions
# across builds. Ad-hoc signatures change identity with every build.
SIGN_IDENTITY="${DIGI_SUITE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"((Apple Development|Developer ID Application|Mac Developer):[^"]+)".*/\1/p' | head -n 1 || true)"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  if ! codesign --force --deep --options runtime --entitlements DigiApp.entitlements --sign "$SIGN_IDENTITY" "$APP"; then
    echo "Certificate signing failed; using ad-hoc signing."
    codesign --force --deep --sign - "$APP"
  fi
else
  echo "No Apple signing certificate found; using ad-hoc signing."
  codesign --force --deep --sign - "$APP"
fi
echo "Built: $APP"
if [ "${NO_OPEN:-}" != "1" ]; then
  open -n "$APP"
  echo "LAUNCHED $APP_NAME $VERSION"
fi
