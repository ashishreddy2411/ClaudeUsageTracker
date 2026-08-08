# Contributing

Thank you for helping improve ClaudeUsageBar. Keep changes focused, explain the
user impact, and preserve the project's read-only privacy model.

## Development setup

You need macOS 13 or later and Xcode 15 or later.

```bash
git clone <your-fork-url>
cd ClaudeUsageBar
open ClaudeUsageBar.xcodeproj
```

Use a short branch name such as `fix/refresh-error-state` or
`docs/security-boundaries`.

Live usage testing requires an existing official Claude Code sign-in. Install
and sign in using
[Anthropic's setup guide](https://code.claude.com/docs/en/setup), then click
**Connect Claude Code** to grant read-only Keychain access. If setup is
required, complete it outside ClaudeUsageBar, return to the app, and click
**Retry**. ClaudeUsageBar must never discover or execute `claude`.

## Build and test

Before opening a pull request, run:

```bash
xcodebuild test \
  -project ClaudeUsageBar.xcodeproj \
  -scheme ClaudeUsageBar \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-"

swift Scripts/smoke-logic.swift
```

For a local ad-hoc application build:

```bash
./Scripts/build.sh
```

`Scripts/create-dmg.sh` creates a local, unnotarized test DMG. Do not publish
that artifact as an official release. `Scripts/release.sh` is maintainer-only
and intentionally fails unless valid Developer ID and notarization
configuration is supplied outside the repository.

The source repository may be published with the disclaimers in
[README.md](README.md). Public binaries are a separate release: do not publish
an app or DMG without both written Anthropic approval for the undocumented
consumer usage endpoint and valid Apple Developer ID signing/notarization
credentials.

## Test data and secrets

Never commit real credentials or credential-derived data. This includes:

- Claude Code Keychain exports or credential files
- Access or refresh tokens, including truncated token previews
- Authorization headers, cookies, API keys, or environment files
- Apple signing certificates, provisioning profiles, `.p8` files, or
  notarization credentials
- Logs or screenshots containing account identifiers or private usage data

Tests must use unmistakably fake, minimal fixtures such as
`credential-fixture`. A test must not depend on a contributor's Keychain,
network access, account, or subscription.

## Pull requests

- Keep each pull request limited to one concern.
- Add or update tests for behavior changes and failure paths.
- Describe privacy, Keychain, network, or logging effects explicitly.
- Update documentation when setup, compatibility, or release behavior changes.
- Preserve opt-in, read-only Keychain access. Do not add executable discovery,
  subprocess or shell authentication, an app-owned OAuth flow, telemetry, or
  persisted credential material.
- Keep disconnect app-local: disable future reads and clear ClaudeUsageBar state
  without changing or deleting Claude Code credentials.
- Do not claim or imply Anthropic affiliation or endorsement.

Use Conventional Commit style for pull request titles, for example:
`fix(network): handle an unavailable usage endpoint`.

## Reporting security issues

Follow [SECURITY.md](SECURITY.md). Do not report vulnerabilities or secrets in
public issues.
