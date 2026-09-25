#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shade-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Shade/DimmingPolicy.swift Sources/Shade/ShadeSettings.swift Tests/CoreTests.swift \
    -framework Cocoa -o "$TEST_DIR/core-tests"
"$TEST_DIR/core-tests"
if [ "${1:-}" = "--integration" ]; then
    SHADE_TEST_SOURCES=()
    for SHADE_SOURCE in Sources/Shade/*.swift; do
        [ "$SHADE_SOURCE" = "Sources/Shade/main.swift" ] || SHADE_TEST_SOURCES+=("$SHADE_SOURCE")
    done
    swiftc "${SHADE_TEST_SOURCES[@]}" Tests/NativeTests.swift -framework Cocoa -framework Carbon -framework ServiceManagement -o "$TEST_DIR/native-tests"
    "$TEST_DIR/native-tests"
fi
