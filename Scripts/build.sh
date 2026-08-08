#!/usr/bin/env bash
# Local ad-hoc build only. Public artifacts must use Scripts/release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="ClaudeUsageBar"
SCHEME="ClaudeUsageBar"
PROJECT="$ROOT/ClaudeUsageBar.xcodeproj"
ARCHIVE_PATH="$DIST/$APP_NAME.xcarchive"
EXPORT_PATH="$DIST/export"
DERIVED_DATA="$ROOT/build/LocalArchiveDerivedData"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode from the Mac App Store, then:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: active developer directory is not a full Xcode install." >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

mkdir -p "$DIST"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DIST/$APP_NAME.app" "$DERIVED_DATA"

echo "==> Archiving $APP_NAME (Release, universal)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean archive

APP_FROM_ARCHIVE="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_FROM_ARCHIVE" ]]; then
  echo "error: archive did not produce $APP_NAME.app" >&2
  exit 1
fi

cp -R "$APP_FROM_ARCHIVE" "$DIST/$APP_NAME.app"

# Cloud/file-provider metadata can invalidate any signature. Remove it only from
# the copied build product, then ad-hoc sign the local artifact.
xattr -cr "$DIST/$APP_NAME.app"

# Prefer a stable self-signed identity when one exists. An ad-hoc signature's
# designated requirement is the binary's cdhash, so every rebuild is a different code
# identity and macOS re-prompts for the Claude Code Keychain item each time. A
# certificate-anchored requirement is stable across rebuilds, so an "Always Allow"
# grant survives. Run Scripts/create-local-signing-identity.sh to create one.
LOCAL_IDENTITY="${LOCAL_SIGNING_IDENTITY:-ClaudeUsageBar Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LOCAL_IDENTITY"; then
  echo "==> Signing with local identity: $LOCAL_IDENTITY"
  codesign --force --deep --options runtime --sign "$LOCAL_IDENTITY" "$DIST/$APP_NAME.app"
else
  echo "==> No local signing identity found; falling back to ad-hoc."
  echo "    Keychain access prompts will return after every rebuild."
  echo "    Fix: ./Scripts/create-local-signing-identity.sh"
  codesign --force --deep --options runtime --sign - "$DIST/$APP_NAME.app"
fi
codesign --verify --deep --strict "$DIST/$APP_NAME.app"

echo "==> Built: $DIST/$APP_NAME.app"
echo "    This ad-hoc artifact is for local development, not public distribution."
echo "    Tip: open the project in Xcode and run the ClaudeUsageBar scheme for day-to-day development."
