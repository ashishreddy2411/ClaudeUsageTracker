#!/usr/bin/env bash
# Local ad-hoc DMG only. Public artifacts must use Scripts/release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClaudeUsageBar.app"
DMG_NAME="ClaudeUsageBar-Installer.dmg"
DMG_PATH="$DIST/$DMG_NAME"
STAGE="$DIST/dmg-stage"
VOLUME_NAME="ClaudeUsageBar"

if [[ ! -d "$APP" ]]; then
  echo "==> App not found; running Scripts/build.sh first"
  "$ROOT/Scripts/build.sh"
fi

if [[ ! -d "$APP" ]]; then
  echo "error: $APP missing after build" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Creating DMG with create-dmg"
  create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "ClaudeUsageBar.app" 150 200 \
    --app-drop-link 450 200 \
    --hide-extension "ClaudeUsageBar.app" \
    "$DMG_PATH" \
    "$STAGE"
else
  echo "==> create-dmg not found; using hdiutil fallback"
  echo "    (optional: brew install create-dmg)"
  TMP_DMG="$DIST/pack.tmp.dmg"
  rm -f "$TMP_DMG"
  hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDRW \
    "$TMP_DMG"
  hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
  rm -f "$TMP_DMG"
fi

rm -rf "$STAGE"
echo "==> Created: $DMG_PATH"
echo "    This ad-hoc DMG is for local development, not public distribution."
