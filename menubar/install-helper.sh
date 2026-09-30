#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 1
mode=${1:?}
source_app=${2:?}
label=local.clipboardhid.helper
helper=/Library/PrivilegedHelperTools/local.clipboardhid.helper
plist=/Library/LaunchDaemons/local.clipboardhid.helper.plist
app='/Applications/KeyBridge.app'
if [ "$mode" = remove ]; then
  /bin/launchctl bootout "system/$label" 2>/dev/null || true
  /bin/rm -f "$plist" "$helper"
  /bin/rm -f /var/run/local.clipboardhid/control.sock
  /bin/rmdir /var/run/local.clipboardhid 2>/dev/null || true
  exit 0
fi
[ "$mode" = install ] || exit 2
[ ! -L "$app" ] && [ ! -L "$helper" ] && [ ! -L "$plist" ] || exit 4
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = app.keybridge.mac ] || exit 4
if [ -e "$app" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = app.keybridge.mac ] || exit 4
fi
/usr/bin/codesign --verify --deep --strict "$source_app"
development=$(/usr/libexec/PlistBuddy -c 'Print :KeyBridgeDevelopmentBuild' "$source_app/Contents/Info.plist" 2>/dev/null || true)
release_team=$(/usr/libexec/PlistBuddy -c 'Print :KeyBridgeSigningTeamID' "$source_app/Contents/Info.plist" 2>/dev/null || true)
if [ "$development" != true ] && [ "$development" != YES ]; then
  [ -n "$release_team" ] || exit 5
  /usr/bin/codesign -d --verbose=4 "$source_app" 2>&1 | /usr/bin/grep -qx "TeamIdentifier=$release_team" || exit 5
fi
if [ "$source_app" != "$app" ]; then
  stage=$(/usr/bin/mktemp -d /Applications/.clipboardhid.XXXXXX)
  trap '/bin/rm -rf "$stage"' EXIT
  /usr/bin/ditto "$source_app" "$stage/KeyBridge.app"
  /usr/sbin/chown -R root:wheel "$stage/KeyBridge.app"
  /bin/chmod -R go-w "$stage/KeyBridge.app"
  /usr/bin/codesign --verify --deep --strict "$stage/KeyBridge.app"
  # Replace only this application's fixed installation path.
  if [ -e "$app" ]; then /bin/mv "$app" "$stage/previous.app"; fi
  /bin/mv "$stage/KeyBridge.app" "$app"
fi
/usr/sbin/chown -R root:wheel "$app"
/bin/chmod -R go-w "$app"
/usr/bin/codesign --verify --deep --strict "$app"
hash=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
[[ "$hash" =~ ^[a-f0-9]{40}$ ]] || exit 3
/bin/launchctl bootout "system/$label" 2>/dev/null || true
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 "$app/Contents/Library/LaunchServices/local.clipboardhid.helper" "$helper"
/usr/bin/codesign --verify "$helper"
/usr/bin/install -d -o root -g wheel -m 755 /Library/LaunchDaemons
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$helper</string><string>--helper</string><string>$hash</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"
/usr/bin/plutil -lint "$plist" >/dev/null
/bin/launchctl bootstrap system "$plist"
