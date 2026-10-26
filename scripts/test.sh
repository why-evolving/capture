#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TOOLCHAIN_USR="$(cd "$(dirname "$(xcrun --find swift)")/.." && pwd)"
TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# The macOS 27 CLT includes Swift Testing, but Swift Build's incremental planner
# can omit its macro library after a production build. Load that bundled library
# explicitly rather than installing a toolchain or depending on a warm cache.
if [[ -f "$TESTING_PLUGIN" ]]; then
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" "$@"
else
    swift test --disable-xctest "$@"
fi
