#!/usr/bin/env bash
# Compiles the shim's password reveal relay (CEFShim/src/password_reveal_relay.h,
# no CEF needed) and runs its cases. Small: one clang++ call (c++ off macOS).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-reveal-relay.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if command -v xcrun >/dev/null 2>&1; then cxx=(xcrun clang++); else cxx=(c++); fi
"${cxx[@]}" -std=c++17 -Wall -Werror -O2 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/password_reveal_relay_test.cpp"
"$work/test"
