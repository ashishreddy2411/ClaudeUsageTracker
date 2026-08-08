# Security Policy

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities or include credentials,
authorization headers, Keychain exports, private keys, or personal account data
in any report.

Use GitHub's private vulnerability reporting feature from the repository's
**Security** tab. If private reporting is not yet available, contact the
maintainer through their GitHub profile and request a private reporting channel
without sending vulnerability details.

Please include:

- The affected version or commit
- Reproduction steps and expected impact
- The relevant macOS and Xcode versions
- Sanitized logs or a minimal reproduction, if available
- Any suggested mitigation

The maintainers will acknowledge a complete report as soon as practical,
coordinate remediation and disclosure with the reporter, and publish a security
advisory when users need to take action. Please allow reasonable time for a fix
before public disclosure.

## Supported versions

Security fixes are provided for the latest release and the current `main`
branch. Older releases may be asked to upgrade.

## Privacy and threat boundaries

ClaudeUsageBar is designed to:

- Read the existing Claude Code credential from macOS Keychain only after the
  user explicitly enables the connection
- Keep credentials out of UserDefaults, application logs, analytics, and
  repository fixtures
- Hold the access credential only transiently in process memory
- Send the credential only in an HTTPS authorization header to the allowlisted
  `api.anthropic.com` usage endpoint
- Open Anthropic's official Claude Code setup and sign-in guidance in the
  browser when the user needs to complete setup externally
- Stop future credential reads and clear ClaudeUsageBar's consent, usage state,
  and cache on disconnect

ClaudeUsageBar does not write, refresh, rotate, or delete Claude Code
credentials. It does not store those credentials, read
`~/.claude/.credentials.json`, discover or execute `claude`, or use a subprocess
or shell authentication path. Disconnecting does not log out Claude Code.

This security model does not protect against:

- A compromised macOS account, host, Keychain, or Claude Code installation
- Malicious software running with sufficient local privileges
- Changes, outages, or security properties of Anthropic's services
- Exposure introduced by locally modified builds or untrusted release artifacts

The consumer usage endpoint is not a documented public API and can change or
stop working without notice. Availability of that endpoint is not a security
guarantee.

## Release integrity

Local builds and DMGs are ad-hoc signed and are for development only. Public
binaries must not be distributed until maintainers have written Anthropic
approval for use of the undocumented consumer usage endpoint and Apple
Developer ID/notarization credentials. Once both gates are met, binaries should
be built with a Developer ID Application certificate, notarized by Apple,
stapled, and published with a SHA-256 checksum. Signing and notarization
credentials must never be stored in this repository.

Publishing the source repository with its independent-project and
undocumented-endpoint disclaimers is separate from releasing a compiled app or
DMG.
