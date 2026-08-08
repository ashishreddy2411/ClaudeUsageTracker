# Pull request

## What

Describe the user-visible or maintenance change.

## Why

Explain the problem this solves and link any related issue.

## How to test

1. List the commands and manual steps used to verify the change.
2. Include relevant edge cases and failure paths.

## Privacy and security impact

Describe any effect on Keychain access, credentials, network destinations,
logging, local persistence, notifications, or release signing. Write "None" if
there is no impact.

## Screenshots

Add before/after screenshots for user-interface changes, with private account
data removed.

## Checklist

- [ ] Xcode tests pass locally.
- [ ] The smoke test passes locally.
- [ ] Tests were added or updated for behavior changes.
- [ ] Documentation was updated where needed.
- [ ] No credentials, authorization headers, private keys, real account data,
      or environment-specific values are included.
- [ ] Logs and error messages do not expose credential material.
- [ ] New network destinations are documented and allowlisted.
- [ ] The change preserves explicit user consent for Keychain access.
- [ ] The change does not discover or execute `claude`, add subprocess/shell
      authentication, or implement an app-owned OAuth flow.
- [ ] Disconnect remains app-local and does not alter Claude Code credentials
      or sign-in state.
- [ ] Any public binary release change preserves the written Anthropic approval
      and Apple Developer ID/notarization gates.
- [ ] User-facing copy does not imply Anthropic affiliation or endorsement.
- [ ] UI changes include sanitized screenshots.
