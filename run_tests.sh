#!/bin/bash
# Run all test suites: Python hook logic + Swift model logic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "=== Python hook tests ==="
python3 "$ROOT/tests/test_hook.py"

echo ""
echo "=== Swift model tests ==="
# Top-level code is only allowed in a file named main.swift, so stage a copy.
TMP="$(mktemp -d)"
cp "$ROOT/app/tests/model_test.swift" "$TMP/main.swift"
swiftc "$ROOT/app/Sources/Model.swift" "$TMP/main.swift" -o "$TMP/mt"
"$TMP/mt"
rm -rf "$TMP"

echo ""
echo "All test suites passed."
