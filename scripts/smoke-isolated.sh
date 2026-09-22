#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional integration check. Opens two temporary, signed-out Codex instances,
# verifies isolation, then terminates only those exact instances.
mkdir -p build/isolation-smoke
xcrun swiftc Sources/IsolatedProfiles.swift Tests/IsolatedSmoke/main.swift -o build/isolation-smoke/test -framework Cocoa
build/isolation-smoke/test
