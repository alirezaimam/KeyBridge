#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang++ -std=gnu++20 -Wall -Werror \
  -isystem ../../include -isystem ../../vendor/vendor/include \
  -framework AppKit -framework ApplicationServices -framework Security \
  tests/clipboard_tests.mm -o build/tests/clipboard-tests
/usr/bin/codesign --force --sign - build/tests/clipboard-tests
./build/tests/clipboard-tests
