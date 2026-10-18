#!/bin/bash
# Local regressions: fake AI executables, temporary chats/PDFs, and a nonpersistent WebKit fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_CACHE="$PWD/.build/test-cache"
mkdir -p "$TEST_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TEST_CACHE/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$TEST_CACHE/swift}"

# Command Line Tools ships Swift Testing without XCTest. Explicitly name the macro plugin directory
# because some SwiftBuild incremental builds omit it; Xcode/toolchains without this directory use defaults.
SWIFT_BIN=$(xcrun --find swift)
TESTING_PLUGINS="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing"
TEST_ARGS=(--cache-path "$TEST_CACHE/swiftpm" --disable-sandbox --disable-xctest --enable-swift-testing)
if [ -d "$TESTING_PLUGINS" ]; then
  TEST_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
"$SWIFT_BIN" test "${TEST_ARGS[@]}" "$@"
