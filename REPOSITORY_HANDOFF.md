# Public Repository Handoff

This note contains repository metadata and launch guidance only. Do not add
credentials, account identifiers, signing material, or private vulnerability
details here.

## Recommended metadata

- **Repository name:** `ClaudeUsageBar`
- **Description:** Independent macOS menu bar app for viewing session and weekly
  usage bars from an existing Claude Code sign-in.
- **Visibility:** Public
- **License:** MIT
- **Topics:** `macos`, `swift`, `swiftui`, `menu-bar`, `macos-app`,
  `usage-monitoring`, `claude-code`

The proposed name is currently unused in the intended GitHub account. The
description and README must retain the independent-project disclaimer and must
not imply affiliation, endorsement, or official status.

## Branch strategy

- Use `main` as the only permanent branch.
- Protect `main` after the initial push. Require pull requests, the `CI` check,
  resolved review conversations, and disallow force pushes.
- Use short-lived branches named `<type>/<short-description>`, such as
  `fix/keychain-error-copy` or `docs/release-checklist`.
- Squash focused pull requests with Conventional Commit titles.
- Tag releases from `main` as `vMAJOR.MINOR.PATCH`; do not maintain a separate
  long-lived release branch until backports are actually needed.

## Source repository publication

The source may be published under the MIT license after confirming the public
file list, retaining the independent-project disclaimer, and clearly disclosing
that `/api/oauth/usage` is undocumented. Publishing source does not authorize
distribution of an app, DMG, or other compiled artifact.

1. Create one reviewed baseline commit after confirming the public file list.
2. Publish source on `main` and verify the unsigned CI build.
3. Enable GitHub private vulnerability reporting and branch protection.
4. Do not attach locally built apps or DMGs to a tag or GitHub Release.

## Public binary release blockers

Do not publish a binary until both external gates are satisfied:

1. Obtain written Anthropic approval for public binary distribution using the
   undocumented consumer usage endpoint.
2. Obtain Apple Developer Program access, a Developer ID Application
   certificate, and working notarization credentials.

After both gates are met:

1. Build the binary only with `Scripts/release.sh` and the maintainer's external
   signing and notarization configuration.
2. Confirm Developer ID signing, hardened runtime, notarization, stapling, and
   Gatekeeper validation all succeed.
3. Tag the release and attach only the notarized DMG plus its SHA-256 checksum.

Never upload an app or DMG created by `Scripts/build.sh` or
`Scripts/create-dmg.sh` as a public release. Do not add signing or notarization
secrets to GitHub until a release workflow specifically needs them; no
automated release workflow is included in this baseline.

## Before the first public source push

- A screenshot is optional for source publication. Add a sanitized current
  screenshot before announcing the first public binary release.
- Keep the internal `UI-UX-Inspirations/` design research out of public source
  history to avoid brand-guideline and affiliation confusion.
- Confirm generated `build/`, `dist/`, `.cursor/`, and local Xcode user data are
  excluded.
- Run the complete local test suite and inspect the initial staged file list.
