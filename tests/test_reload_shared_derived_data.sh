#!/usr/bin/env bash
# reload.sh gives every tag its own DerivedData unless the checkout's owner names a warm
# one through CMUX_DERIVED_DATA. A tag is not a compiler input, so tags that share a warm
# DerivedData do not recompile; a fresh per-tag directory is always a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real functions, not copies.
eval "$(awk '/^tagged_derived_data_path\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^resolve_tagged_derived_data\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F resolve_tagged_derived_data >/dev/null || fail "resolve_tagged_derived_data not found in reload.sh"

unset CMUX_DERIVED_DATA
[[ "$(resolve_tagged_derived_data one 0 "")" == "$HOME/Library/Developer/Xcode/DerivedData/cmux-one" ]] \
  || fail "without CMUX_DERIVED_DATA the default must stay one directory per tag"
[[ "$(resolve_tagged_derived_data one 0 "")" != "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "two tags must not share a DerivedData by default"

export CMUX_DERIVED_DATA="/tmp/cmux warm/DerivedData"
[[ "$(resolve_tagged_derived_data one 0 "")" == "/tmp/cmux warm/DerivedData" ]] || fail "CMUX_DERIVED_DATA ignored"
[[ "$(resolve_tagged_derived_data one 0 "")" == "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "tags must share the warm DerivedData when CMUX_DERIVED_DATA is set"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must win over CMUX_DERIVED_DATA"

export CMUX_DERIVED_DATA="relative/DerivedData"
if output="$(resolve_tagged_derived_data one 0 "" 2>&1)"; then
  fail "a relative CMUX_DERIVED_DATA must be rejected, got: $output"
fi
[[ "$output" == *"must be an absolute path"* ]] || fail "unclear error for a relative path: $output"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must not be blocked by an invalid CMUX_DERIVED_DATA"
unset CMUX_DERIVED_DATA

# The parser must record --derived-data and the tag default must go through the resolver with it.
awk '/^    --derived-data\)/,/;;/' "$ROOT/scripts/reload.sh" | grep -q 'DERIVED_SET=1' \
  || fail "the --derived-data parser no longer sets DERIVED_SET=1"
grep -Fq 'DERIVED_DATA="$(resolve_tagged_derived_data "$TAG_SLUG" "$DERIVED_SET" "${DERIVED_DATA:-}")"' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not resolve the tag's DerivedData through resolve_tagged_derived_data"

# cmux-debug-cli.sh must look for the tagged CLI where reload.sh built it.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sock="/tmp/cmux-debug-ddtest-$$.sock"
python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(20)
PY
server=$!
disown "$server" 2>/dev/null || true
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock"; rm -rf "$tmp"' EXIT
for _ in $(seq 1 50); do [[ -S "$sock" ]] && break; sleep 0.1; done
[[ -S "$sock" ]] || fail "test socket was not created"
cli_dir="$tmp/dd/Build/Products/Debug/cmux DEV ddtest-$$.app/Contents/Resources/bin"
mkdir -p "$cli_dir"
printf '#!/bin/sh\necho shared-cli "$@"\n' > "$cli_dir/cmux"; chmod +x "$cli_dir/cmux"
out="$(CMUX_TAG="ddtest-$$" CMUX_DERIVED_DATA="$tmp/dd" "$ROOT/scripts/cmux-debug-cli.sh" ping 2>&1)" \
  || fail "cmux-debug-cli.sh did not find the CLI in CMUX_DERIVED_DATA: $out"
[[ "$out" == *"shared-cli"* ]] || fail "cmux-debug-cli.sh ran something else: $out"

echo "PASS: reload.sh shared DerivedData default"
