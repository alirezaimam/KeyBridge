# KeyBridge Go 0.8.0 development build

The menu-bar executable uses Go for the connection lifecycle, retry, clipboard
job ownership, key-release wait, cancellation, and helper protocol. AppKit,
Accessibility, clipboard access, settings UI, and login registration use an
Objective-C cgo adapter. The existing privileged C++ Karabiner helper and its
printable US-ANSI HID mapping are retained. This is not a pure-Go driver.

## Build
Requires macOS 13+, Xcode with command-line tools, and Go 1.27.1 or newer.
The parent Karabiner checkout and its vendor/include dependencies must be present.
From this directory:

    go test -race ./...
    ./build.sh
    ./package.sh

GO_BIN can select a particular Go executable. Output:
dist/KeyBridge.app and dist/KeyBridge-0.8.0-Go.pkg.

## Install and run
Quit the earlier KeyBridge. Open the generated pkg; it installs the app under
/Applications, the existing helper, and the bundled Karabiner prerequisite if
required. Approve the installer administrator prompt. Open
/Applications/KeyBridge.app. Use Allow Accessibility to request macOS approval,
then enable this exact app in System Settings. If macOS requests approval for
the driver, approve it; Enable virtual keyboard invokes the Karabiner manager.
The app automatically retries helper and device connections.

The development build is ad-hoc signed, not Developer ID signed or notarized.
Replacing a development binary may require granting Accessibility again. The
helper authenticates the installed binary's code hash; the installer updates it.
Do not launch an unrelated build and expect the installed helper to accept it.

## Use
Default shortcut: Option-Command-V. Release it before typing starts.
Escape cancels pending or active typing. Cancellation closes the helper socket,
which causes the helper to stop and release its keys; the app reconnects.
Settings include shortcut capture, open at login, length and key delays.
The app reads the clipboard once per accepted shortcut and accepts only
printable US-ASCII. Enter, Tab, newline, Unicode and over-limit text are rejected.
Caps Lock must be off. Clipboard text is never logged or sent over the network.
Owned Go/native job buffers are cleared; macOS pasteboard/framework storage is
outside the app's control.

## Validation and limits
Build, signature verification and automated protocol tests are available.
Tests cover settings, text rejection, wire framing, completion, idle disconnect
and cancellation by connection close. The Go UI and end-to-end VMware typing
still require a live test with the installed helper and granted permissions.
A successful build is not evidence of a successful VMware run.

The installer reuses the existing prerequisite/version policy. It is not an
Internet auto-updater. Driver installation and Accessibility approval remain
subject to macOS consent. Keep the original source until acceptance testing is
complete.
