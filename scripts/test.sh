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
case " $* " in *" --list-tests "*) exec "$SWIFT_BIN" test "${TEST_ARGS[@]}" "$@";; esac

# A run that stops early can still exit 0 (a test scrolling through AppKit with pixel-unit wheel events ends the
# runner's main run loop), so a run passes only with Swift Testing's closing summary line.
LOG="$TEST_CACHE/last-run.log"
status=0
"$SWIFT_BIN" test "${TEST_ARGS[@]}" "$@" 2>&1 | tee "$LOG" || status=$?
if [ "$status" -eq 0 ] && ! grep -q "Test run with .* passed" "$LOG"; then
  echo "error: the test run stopped before Swift Testing's summary line (output in $LOG)" >&2
  status=1
fi
exit "$status"
