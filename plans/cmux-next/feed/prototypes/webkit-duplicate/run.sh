#!/bin/sh
# Builds the prototype with one swiftc call and runs it. The binary starts
# server.py itself, prints a JSON report on stdout and exits (0 = every check
# passed, 1 = a check failed, 2 = watchdog, 3 = server did not start).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/cmux-webkit-duplicate-proto"
mkdir -p "$out"
xcrun swiftc -swift-version 6 -O -o "$out/webkit-duplicate" "$here/main.swift"
exec "$out/webkit-duplicate" "$here" "$out/report.json"
