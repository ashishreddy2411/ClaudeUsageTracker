#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and verify a public DMG.
# Intentionally does not enable shell tracing: signing/notary configuration is sensitive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/release"
APP_NAME="ClaudeUsageBar"
PROJECT="$ROOT/ClaudeUsageBar.xcodeproj"
SCHEME="ClaudeUsageBar"
ARCHIVE="$DIST/$APP_NAME.xcarchive"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-Installer.dmg"
STAGE="$DIST/dmg-stage"
TEST_DERIVED_DATA="$ROOT/build/PublicReleaseTests"
ARCHIVE_DERIVED_DATA="$ROOT/build/PublicReleaseArchive"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER="${APPLE_API_ISSUER:-}"
APPLE_API_PRIVATE_KEY="${APPLE_API_PRIVATE_KEY:-}"
PREFLIGHT_ONLY=false

case "${1:-}" in
  "")
    ;;
  --preflight-only)
    PREFLIGHT_ONLY=true
    ;;
  *)
    echo "error: usage: $0 [--preflight-only]" >&2
    exit 1
    ;;
esac
[[ $# -le 1 ]] || {
  echo "error: usage: $0 [--preflight-only]" >&2
  exit 1
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -n "$SIGNING_IDENTITY" ]] || fail "SIGNING_IDENTITY is required (Developer ID Application: …)"
[[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] \
  || fail "SIGNING_IDENTITY must be a Developer ID Application identity"
[[ -n "$DEVELOPMENT_TEAM" ]] || fail "DEVELOPMENT_TEAM is required"
[[ "$SIGNING_IDENTITY" == *"($DEVELOPMENT_TEAM)"* ]] \
  || fail "SIGNING_IDENTITY does not match DEVELOPMENT_TEAM"

if [[ -z "$NOTARY_PROFILE" ]]; then
  [[ -n "$APPLE_API_KEY_ID" && -n "$APPLE_API_ISSUER" && -n "$APPLE_API_PRIVATE_KEY" ]] \
    || fail "set NOTARY_PROFILE, or APPLE_API_KEY_ID + APPLE_API_ISSUER + APPLE_API_PRIVATE_KEY"
  [[ -f "$APPLE_API_PRIVATE_KEY" ]] || fail "APPLE_API_PRIVATE_KEY must name an existing .p8 file"
fi

for tool in xcodebuild codesign security hdiutil lipo spctl shasum xcrun xattr; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

xcodebuild -version >/dev/null 2>&1 \
  || fail "the active developer directory must be a full Xcode installation"
security find-identity -v -p codesigning \
  | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null \
  || fail "the requested Developer ID Application identity is not available"

echo "==> Validating notarization credentials"
if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || fail "NOTARY_PROFILE could not authenticate with Apple"
else
  xcrun notarytool history \
    --key "$APPLE_API_PRIVATE_KEY" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" >/dev/null \
    || fail "App Store Connect API credentials could not authenticate with Apple"
fi

if [[ "$PREFLIGHT_ONLY" == true ]]; then
  echo "OK: release signing and notarization preflight passed"
  exit 0
fi

echo "==> Running tests"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  -destination "platform=macOS"

rm -rf "$DIST" "$ARCHIVE_DERIVED_DATA"
mkdir -p "$DIST"

echo "==> Archiving universal Release app"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$ARCHIVE_DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  clean archive

ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP" ]] || fail "archive did not contain $APP_NAME.app"
ditto "$ARCHIVED_APP" "$APP"
xattr -cr "$APP"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] \
  || fail "app is not universal (found: $ARCHS)"

echo "==> Developer ID signing app from the inside out"
if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' library; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$library"
  done < <(/usr/bin/find "$APP/Contents/Frameworks" -type f -name "*.dylib" -print0)
fi
while IFS= read -r -d '' bundle; do
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$bundle"
done < <(
  /usr/bin/find "$APP/Contents" -depth -type d \
    \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" -o -name "*.app" \) \
    -print0
)
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"

echo "==> Verifying app and nested signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "runtime" \
  || fail "hardened runtime flag is missing"

echo "==> Packaging drag-to-Applications DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
xattr -cr "$STAGE"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"
rm -rf "$STAGE"

echo "==> Signing DMG"
xattr -cr "$DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG"

echo "==> Submitting DMG to Apple notary service"
if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$DMG" \
    --key "$APPLE_API_PRIVATE_KEY" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
fi

echo "==> Stapling and validating notarization"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Release artifact"
shasum -a 256 "$DMG"
echo "$DMG"
