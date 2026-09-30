# KeyBridge

KeyBridge is a macOS menu-bar app that types a one-time clipboard snapshot
through a real Karabiner Virtual HID keyboard. It is intended for remote
consoles that do not reliably accept synthetic macOS keystrokes.

The product executable is Go. A small Objective-C bridge provides AppKit,
Accessibility, the clipboard, and the menu-bar UI; the privileged helper is a
native adapter because Karabiner's Virtual HID API is C++/Objective-C.

## Compatibility

- macOS 13 or later on Apple silicon.
- Karabiner DriverKit Virtual HID Device 6.2.0 or later.
- The installer checks for that dependency and installs the bundled package
  when it is absent or older. The user does not install it separately.
- VMware WebMKS is validated. Other remote consoles depend on their keyboard
  handling; KeyBridge includes a configurable post-shortcut delay for them.

## Privacy and safety

KeyBridge reads the clipboard once after the user presses its shortcut. It
accepts only printable, single-line US-ASCII, never presses Enter or Tab, and
does not display, log, store, or transmit clipboard text. Accessibility is
needed only to observe the shortcut. Administrator approval is needed only to
install or update the local Virtual HID helper.

## Build

Development builds require Xcode command-line tools, XcodeGen, Go 1.27 or
newer, and a Karabiner DriverKit Virtual HID Device checkout. Set
`KARABINER_ROOT` to that checkout before building; it supplies only the native
Virtual HID headers and libraries.

```sh
cd go/keybridge
export KARABINER_ROOT=/path/to/Karabiner-DriverKit-VirtualHIDDevice
go test -race ./...
./package.sh
```

The package is written to `go/keybridge/dist/`. The development build is
ad-hoc signed. A public release must set `KEYBRIDGE_RELEASE=1` and provide
`KEYBRIDGE_APP_SIGN_IDENTITY`, `KEYBRIDGE_INSTALLER_SIGN_IDENTITY`, and
`KEYBRIDGE_TEAM_ID`, then be notarized and stapled.

## Repository layout

- `go/keybridge/`: Go application, bridge, tests, and build scripts.
- `menubar/`: native privileged helper, its IPC protocol, resources, and icon.
- `src/`: HID mapping and typed-text engine used by the helper.
- `installer-scripts/` and `prereq-scripts/`: package installation lifecycle.
- `tests/`: native helper and protocol tests.
