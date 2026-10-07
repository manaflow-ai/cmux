#!/usr/bin/env bash
# Compiles the shim's per-profile proxy values (CEFShim/src/context_proxy_policy.h,
# no CEF needed) and checks that a remote machine's store sends everything,
# loopback included, to the app's proxy on 127.0.0.1. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/context-proxy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/context_proxy_test.cpp"
"$work/test"
