#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
release="${KEYBRIDGE_RELEASE:-0}"
"$here/build.sh"
work="$(mktemp -d)"
mkdir -p "$work/stage/Applications"
ditto "$here/dist/KeyBridge.app" "$work/stage/Applications/KeyBridge.app"
if [ "$release" = 1 ]; then
  : "${KEYBRIDGE_INSTALLER_SIGN_IDENTITY:?Set the Developer ID Installer identity for a release package}"
  pkgbuild --root "$work/stage" --component-plist "$project/installer/KeyBridge-component.plist" --install-location / --scripts "$project/installer-scripts" --version 0.8.6 --identifier app.keybridge.mac --sign "$KEYBRIDGE_INSTALLER_SIGN_IDENTITY" "$work/KeyBridge-app.pkg"
  pkgbuild --nopayload --scripts "$project/prereq-scripts" --version 0.8.6 --identifier app.keybridge.prerequisites --sign "$KEYBRIDGE_INSTALLER_SIGN_IDENTITY" "$work/KeyBridge-prerequisites.pkg"
else
  pkgbuild --root "$work/stage" --component-plist "$project/installer/KeyBridge-component.plist" --install-location / --scripts "$project/installer-scripts" --version 0.8.6 --identifier app.keybridge.mac "$work/KeyBridge-app.pkg"
  pkgbuild --nopayload --scripts "$project/prereq-scripts" --version 0.8.6 --identifier app.keybridge.prerequisites "$work/KeyBridge-prerequisites.pkg"
fi
sed 's/0.7.4/0.8.6/g' "$project/installer/Distribution.xml" > "$work/Distribution.xml"
if [ "$release" = 1 ]; then
  productbuild --distribution "$work/Distribution.xml" --package-path "$work" --sign "$KEYBRIDGE_INSTALLER_SIGN_IDENTITY" "$here/dist/KeyBridge-0.8.6-Go.pkg"
else
  productbuild --distribution "$work/Distribution.xml" --package-path "$work" "$here/dist/KeyBridge-0.8.6-Go.pkg"
fi
