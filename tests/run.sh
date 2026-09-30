#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
karabiner_root="${KARABINER_ROOT:-}"
[ -n "$karabiner_root" ] && [ -d "$karabiner_root/include" ] && [ -d "$karabiner_root/vendor/vendor/include" ] || {
  echo "Set KARABINER_ROOT to a Karabiner-DriverKit-VirtualHIDDevice checkout." >&2
  exit 2
}
mkdir -p build/tests
xcrun clang++ -std=gnu++20 -Wall -Werror \
  -isystem "$karabiner_root/include" -isystem "$karabiner_root/vendor/vendor/include" \
  -framework AppKit -framework ApplicationServices -framework Security \
  tests/clipboard_tests.mm -o build/tests/clipboard-tests
/usr/bin/codesign --force --sign - build/tests/clipboard-tests
./build/tests/clipboard-tests
