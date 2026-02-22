#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="SimctlHelperUI.xcodeproj"
SCHEME="SimctlHelperUI"
CONFIGURATION="Release"
TEAM_ID="${TEAM_ID:-X7H5D9Q5T4}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
VOLUME_NAME="${VOLUME_NAME:-SimctlHelperUI}"

VERSION=""
IDENTITY="${IDENTITY:-}"
NOTARIZE=false
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CLEAN=false

usage() {
  cat <<'EOF'
Builds a macOS Release archive, exports .app, and creates a DMG.

Usage:
  scripts/release-dmg.sh [options]

Options:
  --version <version>          Override DMG/app version label (default: MARKETING_VERSION).
  --team-id <team_id>          Apple team id for export options plist.
  --identity <codesign_name>   Developer ID identity for DMG signing.
  --notarize                   Submit DMG to Apple notarization (requires --identity + --notary-profile).
  --notary-profile <profile>   notarytool keychain profile name.
  --clean                      Remove build directory before building.
  -h, --help                   Show this help.

Environment overrides:
  TEAM_ID, BUILD_DIR, VOLUME_NAME, IDENTITY, NOTARY_PROFILE
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --notarize)
      NOTARIZE=true
      shift
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

require_cmd xcodebuild
require_cmd hdiutil
require_cmd codesign

if [[ "$NOTARIZE" == true ]]; then
  require_cmd xcrun
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(
    xcodebuild -project "$ROOT_DIR/$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings \
      | awk -F' = ' '/MARKETING_VERSION/ { print $2; exit }'
  )"
fi
[[ -n "$VERSION" ]] || fail "Could not resolve app version (MARKETING_VERSION)."

if [[ "$NOTARIZE" == true && -z "$IDENTITY" ]]; then
  fail "--notarize requires --identity."
fi

if [[ "$NOTARIZE" == true && -z "$NOTARY_PROFILE" ]]; then
  fail "--notarize requires --notary-profile (keychain profile for notarytool)."
fi

ARCHIVE_PATH="$BUILD_DIR/${SCHEME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_ROOT="$BUILD_DIR/dmg-root"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
DMG_PATH="$BUILD_DIR/${SCHEME}-${VERSION}.dmg"

if [[ "$CLEAN" == true ]]; then
  rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
</dict>
</plist>
EOF

echo "==> Archiving ${SCHEME} (${CONFIGURATION})"
xcodebuild archive \
  -project "$ROOT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -name "*.app" -type d | head -n 1)"
fi
[[ -d "$APP_PATH" ]] || fail "Exported app not found in $EXPORT_DIR"

echo "==> Preparing DMG contents"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -sfn /Applications "$DMG_ROOT/Applications"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov -format UDZO \
  "$DMG_PATH"

if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
fi

if [[ "$NOTARIZE" == true ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "Done: $DMG_PATH"
