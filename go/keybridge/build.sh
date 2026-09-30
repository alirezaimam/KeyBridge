#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
output="$here/dist"
go_bin="${GO_BIN:-go}"
release="${KEYBRIDGE_RELEASE:-0}"
karabiner_root="${KARABINER_ROOT:-}"
[ -n "$karabiner_root" ] && [ -d "$karabiner_root/include" ] && [ -d "$karabiner_root/vendor/vendor/include" ] || {
  echo "Set KARABINER_ROOT to a Karabiner-DriverKit-VirtualHIDDevice checkout." >&2
  exit 2
}
mkdir -p "$output"
export GOCACHE="$here/.cache/go"
cd "$here"
"$go_bin" test ./...
(
  cd "$project"
  xcodegen generate >/dev/null
)
"$go_bin" build -trimpath -o "$output/KeyBridge" ./cmd/keybridge
xcodebuild -project "$project/virtual-hid-device-service-client.xcodeproj"  -scheme ClipboardHID -configuration Release -derivedDataPath "$here/.cache/xcode"  SYMROOT="$output/native" KARABINER_ROOT="$karabiner_root" build > "$output/native-build.log" 2>&1
app="$output/KeyBridge.app"
ditto "$output/native/Release/KeyBridge.app" "$app"
cp "$output/KeyBridge" "$app/Contents/MacOS/KeyBridge"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.8.6' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 20' "$app/Contents/Info.plist"
if [ "$release" = 1 ]; then
  : "${KEYBRIDGE_APP_SIGN_IDENTITY:?Set the Developer ID Application identity for a release build}"
  : "${KEYBRIDGE_TEAM_ID:?Set the Developer ID team identifier for a release build}"
  /usr/libexec/PlistBuddy -c 'Add :KeyBridgeReleaseBuild bool true' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :KeyBridgeSigningTeamID string $KEYBRIDGE_TEAM_ID" "$app/Contents/Info.plist"
  codesign --force --deep --sign "$KEYBRIDGE_APP_SIGN_IDENTITY" --options runtime --timestamp "$app"
else
  /usr/libexec/PlistBuddy -c 'Add :KeyBridgeDevelopmentBuild bool true' "$app/Contents/Info.plist"
  codesign --force --sign - --options runtime "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built: $app"
