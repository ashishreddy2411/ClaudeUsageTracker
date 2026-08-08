#!/usr/bin/env bash
# Creates a self-signed code signing identity for LOCAL development only.
#
# Why this exists
# ---------------
# Scripts/build.sh previously ad-hoc signed (`codesign --sign -`). An ad-hoc
# signature's designated requirement is the cdhash of that exact binary, so every
# rebuild produces a different code identity. macOS therefore treats each build as a
# new application, and any Keychain "Always Allow" grant the user gave to the previous
# build no longer matches -- the Claude Code credential prompt returns on every build.
#
# A stable self-signed identity gives the app a designated requirement anchored to a
# certificate rather than a hash, so the grant survives rebuilds.
#
# This identity is NOT a Developer ID. It cannot notarize and must never be used for
# public distribution; Scripts/release.sh remains the only release path.
set -euo pipefail

IDENTITY_NAME="${LOCAL_SIGNING_IDENTITY:-ClaudeUsageBar Local Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALIDITY_DAYS="${LOCAL_SIGNING_VALIDITY_DAYS:-3650}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  echo "==> Identity already present: $IDENTITY_NAME"
  echo "    Nothing to do. Run ./Scripts/build.sh to use it."
  exit 0
fi

WORKDIR="$(mktemp -d)"
# Private key material must not survive this script, even on failure.
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Generating a self-signed code signing certificate: $IDENTITY_NAME"

# extendedKeyUsage=codeSigning is what makes `security find-identity -p codesigning`
# and codesign(1) accept this certificate.
cat > "$WORKDIR/openssl.cnf" <<'CONF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_code_sign

[ dn ]
CN = PLACEHOLDER_CN

[ v3_code_sign ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

# Substitute rather than interpolate into the heredoc so a name containing shell
# metacharacters cannot alter the config.
python3 - "$WORKDIR/openssl.cnf" "$IDENTITY_NAME" <<'PY'
import sys
path, cn = sys.argv[1], sys.argv[2]
with open(path) as handle:
    text = handle.read()
with open(path, "w") as handle:
    handle.write(text.replace("PLACEHOLDER_CN", cn))
PY

openssl req -x509 \
  -newkey rsa:2048 \
  -keyout "$WORKDIR/key.pem" \
  -out "$WORKDIR/cert.pem" \
  -days "$VALIDITY_DAYS" \
  -nodes \
  -sha256 \
  -config "$WORKDIR/openssl.cnf" >/dev/null 2>&1

# An empty export password is fine: the file lives only inside $WORKDIR for the
# duration of the import and is removed by the EXIT trap.
openssl pkcs12 -export \
  -inkey "$WORKDIR/key.pem" \
  -in "$WORKDIR/cert.pem" \
  -name "$IDENTITY_NAME" \
  -out "$WORKDIR/identity.p12" \
  -passout pass: >/dev/null 2>&1

echo "==> Importing into your login keychain"
echo "    macOS will ask for your login password."
# -T codesign pre-authorizes codesign to use the key without a prompt per build.
security import "$WORKDIR/identity.p12" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

echo "==> Trusting the certificate for code signing"
echo "    macOS will ask for your login password again."
# -r trustAsRoot with -p codeSign scopes trust to code signing for this user only.
# This does NOT add a system-wide root and does NOT require sudo.
security add-trusted-cert \
  -d \
  -r trustAsRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$WORKDIR/cert.pem"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  echo "error: identity was imported but is not usable for code signing." >&2
  echo "  Open Keychain Access, find '$IDENTITY_NAME', and set" >&2
  echo "  Trust -> Code Signing to 'Always Trust'." >&2
  exit 1
fi

cat <<EOF

==> Done: $IDENTITY_NAME

Next:
  1. ./Scripts/build.sh          # now signs with this stable identity
  2. Launch the app, click refresh, choose **Always Allow** in the Keychain prompt.

Rebuilds keep the same designated requirement, so that grant now survives them.
Claude Code rewriting its own credential can still reset the item's access list; that
is outside this app's control.

To remove this identity later:
  security delete-identity -c "$IDENTITY_NAME" "$KEYCHAIN"
EOF
