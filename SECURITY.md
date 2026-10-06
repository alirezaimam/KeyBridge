# Security Policy

## System and Scope

KeyBridge is a local macOS menu-bar application. It reads one user-requested
clipboard snapshot and sends validated printable US-ASCII text through a local
Karabiner Virtual HID keyboard. The repository includes the Go application,
its Objective-C AppKit bridge, a root-owned local helper, installer scripts,
and a bundled Karabiner dependency package.

KeyBridge has no network service, account system, telemetry, or cloud API.

## Threat Model and Trust Boundaries

Clipboard text is private and potentially sensitive. The macOS Accessibility
permission is trusted only to observe the configured shortcut. The application
process is unprivileged; the local helper runs as root to access the virtual
HID service.

The helper socket is a trust boundary. The helper must accept a request only
from the authenticated installed KeyBridge application and must reject other
local processes. Installer packages and helper updates are also trust
boundaries because they write root-owned files and launch daemons.

## Security Invariants

- Clipboard text must not be logged, stored after the typing job, or transmitted.
- A job must read the clipboard once and type only that snapshot.
- Only printable, single-line US-ASCII within the configured maximum length is
  accepted. Enter, Tab, control characters, and Unicode are rejected.
- Cancellation and failure must release virtual keyboard keys.
- The helper must authenticate clients, validate all protocol inputs, and keep
  its socket, lock, and installed files protected from untrusted replacement.
- Release packages must be Developer ID signed, notarized, and stapled.

## Reportable Findings and Severity Context

Report issues that could expose clipboard text, permit an untrusted local
process to type through the helper, bypass client authentication or code-signing
checks, retain keyboard state after failure, allow unsafe privileged file
writes, or compromise release-package integrity.

## Reporting a Vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting for
this repository. Include a minimal reproduction using harmless sample text,
affected version, macOS version, impact, and any mitigation. Do not include
passwords, tokens, or real clipboard contents.

## Out of Scope and Limitations

Remote-console behavior outside the validated VMware WebMKS and Parallels
scenarios is not a security guarantee. macOS, Karabiner DriverKit, Xcode, and
the bundled third-party package remain external dependencies and should be
reported upstream when the defect is in those components.
