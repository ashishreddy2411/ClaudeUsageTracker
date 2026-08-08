#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="$ROOT/Scripts/release.sh"
TMP="$(mktemp -d)"
BIN="$TMP/bin"
OUTPUT="$TMP/output"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN"

for tool in codesign hdiutil lipo spctl shasum xattr; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/$tool"
  chmod +x "$BIN/$tool"
done

cat >"$BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$BIN/security" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_IDENTITY_AVAILABLE:-0}" == 1 ]]; then
  printf '  1) FAKEHASH "%s"\n' "$SIGNING_IDENTITY"
fi
exit 0
EOF

cat >"$BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_NOTARY_OK:-0}" == 1 ]]
EOF

chmod +x "$BIN/xcodebuild" "$BIN/security" "$BIN/xcrun"

expect_failure() {
  if "$@" >"$OUTPUT" 2>&1; then
    echo "error: command unexpectedly passed: $*" >&2
    exit 1
  fi
}

BASE_ENV=(
  env
  "PATH=$BIN:$PATH"
  "SIGNING_IDENTITY=Developer ID Application: Example (TEAM123)"
  "DEVELOPMENT_TEAM=TEAM123"
  "NOTARY_PROFILE=ClaudeUsageBar-Test"
)

expect_failure env "PATH=$BIN:$PATH" bash "$RELEASE" --preflight-only
expect_failure env \
  "PATH=$BIN:$PATH" \
  "SIGNING_IDENTITY=Developer ID Application: Example (OTHER)" \
  "DEVELOPMENT_TEAM=TEAM123" \
  "NOTARY_PROFILE=ClaudeUsageBar-Test" \
  bash "$RELEASE" --preflight-only
expect_failure "${BASE_ENV[@]}" \
  "FAKE_IDENTITY_AVAILABLE=0" \
  "FAKE_NOTARY_OK=1" \
  bash "$RELEASE" --preflight-only
expect_failure "${BASE_ENV[@]}" \
  "FAKE_IDENTITY_AVAILABLE=1" \
  "FAKE_NOTARY_OK=0" \
  bash "$RELEASE" --preflight-only
expect_failure env \
  "PATH=$BIN:$PATH" \
  "SIGNING_IDENTITY=Developer ID Application: Example (TEAM123)" \
  "DEVELOPMENT_TEAM=TEAM123" \
  "APPLE_API_KEY_ID=KEY123" \
  "APPLE_API_ISSUER=00000000-0000-0000-0000-000000000000" \
  "APPLE_API_PRIVATE_KEY=$TMP/missing.p8" \
  bash "$RELEASE" --preflight-only

"${BASE_ENV[@]}" \
  "FAKE_IDENTITY_AVAILABLE=1" \
  "FAKE_NOTARY_OK=1" \
  bash "$RELEASE" --preflight-only >"$OUTPUT"

grep -q "preflight passed" "$OUTPUT"
echo "OK: release preflight fails closed"
