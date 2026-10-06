# KeyBridge

> Type clipboard text through a real macOS virtual keyboard for VMware and
> other remote consoles that do not reliably accept synthetic keystrokes.

KeyBridge is a macOS menu-bar application. Press its shortcut and it reads one
snapshot of the clipboard, validates it, and types the text through the
Karabiner Virtual HID keyboard. It has no network feature, telemetry, account,
or cloud service.

## Status

KeyBridge is an early macOS project. VMware WebMKS and Parallels Desktop have
been manually validated. It is not yet a signed and notarized public release.

## How it works

```text
Clipboard snapshot → validation → local privileged helper → virtual HID keyboard → focused app
```

The user starts this flow explicitly with the configured shortcut. The app
never invokes Paste, does not send Enter or Tab, and never logs, stores, or
transmits clipboard text.

## Compatibility

- Apple silicon Macs running macOS 13 or later.
- Karabiner DriverKit Virtual HID Device 6.2.0 or later.
- The installer checks the installed dependency and installs its bundled copy
  only when it is missing or too old.
- The initial keyboard layout profile is US ANSI and accepts printable,
  single-line ASCII only.

## Install and use

For a development package, build it as described below and open the generated
`.pkg`. It installs KeyBridge in `/Applications` and configures the local helper.
macOS administrator approval is required for that install. Grant Accessibility
to the installed `/Applications/KeyBridge.app`; it is used solely to observe
the global shortcut.

The default shortcut is Option-Command-V. Release the keys before typing
starts. Escape cancels a pending or active job. The menu-bar settings let you
change the shortcut, maximum text length, typing delays, and login behavior.

## Privacy and safety

KeyBridge reads the pasteboard once for each accepted shortcut and keeps text
only for the duration of that typing job. It rejects newlines, Tab, Enter,
Unicode, control characters, and text over the configured length. The
privileged helper accepts requests only from the installed KeyBridge app.

See [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## Build from source

Development builds require macOS, Xcode command-line tools, XcodeGen, Go
1.27.1 or newer, and a checkout of
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice).
The Karabiner checkout supplies only native headers and libraries while
building.

```sh
git clone https://github.com/alirezaimam/KeyBridge.git
cd KeyBridge/go/keybridge
export KARABINER_ROOT=/path/to/Karabiner-DriverKit-VirtualHIDDevice
go test -race ./...
./package.sh
```

The package is written to `go/keybridge/dist/`. The normal development build
is ad-hoc signed. A distributable release requires a Developer ID Application
certificate, a Developer ID Installer certificate, notarization, and stapling:

```sh
export KEYBRIDGE_RELEASE=1
export KEYBRIDGE_APP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export KEYBRIDGE_INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Name (TEAMID)'
export KEYBRIDGE_TEAM_ID=TEAMID
./package.sh
```

## Repository layout

- `go/keybridge/` — Go application, Objective-C bridge, build scripts, and Go tests.
- `menubar/` — native privileged helper, IPC protocol, resources, and icon.
- `src/` — HID mapping and typed-text engine used by the helper.
- `installer-scripts/` and `prereq-scripts/` — package lifecycle scripts.
- `tests/` — native helper and protocol tests.

## AI-assisted development

The current codebase, documentation, and visual assets were produced with
substantial assistance from generative AI under the project owner's direction.
They remain subject to human review, testing, licensing review, and security
assessment before a public release. Details are in [AI_DISCLOSURE.md](AI_DISCLOSURE.md).

## Contributing and support

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Please
report security issues privately as described in [SECURITY.md](SECURITY.md),
rather than through a public issue.

KeyBridge is available under the [MIT License](LICENSE).
