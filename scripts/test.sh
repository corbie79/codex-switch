#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc Sources/main.swift -o build/CodexAccountSwitcher-tests -framework Cocoa -framework Security
build/CodexAccountSwitcher-tests --self-test "$@"
