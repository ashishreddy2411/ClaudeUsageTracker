## What changed

<!-- One or two sentences. What does this do from a user's point of view? -->

## Why

<!-- The problem it solves. Link an issue if there is one: Closes #123 -->

## How to test

<!-- The steps you actually ran. Include the failure case if you fixed a bug. -->

1.

## Checklist

- [ ] `xcodebuild test` and `swift Scripts/smoke-logic.swift` pass locally
- [ ] Tests added or updated for behaviour changes
- [ ] No credentials, tokens, or unsanitised screenshots in the diff
- [ ] Keychain access stays read-only and opt-in — nothing writes, refreshes, or
      deletes the Claude Code item, executes `claude`, or adds an OAuth flow
- [ ] UI copy does not imply Anthropic affiliation or endorsement

<!-- Screenshots welcome for UI changes. Crop out real usage numbers and any
     other status items you would rather not publish. -->
