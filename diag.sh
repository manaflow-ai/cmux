#!/bin/bash
set -x
OUT=${FAST_CHECKS_OUT:-/tmp/out}; mkdir -p "$OUT"
cd cmux-tui
ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib protocol:: > "$OUT/protocol.log" 2>&1
cp spec/acpmux-protocol.json spec/acpmux-abi.surface.json "$OUT/" 2>/dev/null
find . -path ./target -prune -o -name 'acpmux-protocol.json' -print -o -name 'acpmux-abi.surface.json' -print >> "$OUT/protocol.log"
git status --short > "$OUT/git-status-after-bless.txt"
git diff > "$OUT/bless.diff"
cargo test -p acpmux --lib every_tool_schema_fits -- --nocapture > "$OUT/schema.log" 2>&1
cargo test -p acpmux --lib -- list_tee link_v2 omit_time_breakdown reopen_attach_bytes ls_far help_examples model_hint cell_report agent_login connections home_writers test_hooks --nocapture > "$OUT/lib.log" 2>&1
ACPMUX_LIST_STREAM_BLESS=1 cargo test -p acpmux --lib sidebar_mirror > "$OUT/mirror.log" 2>&1
git diff --stat >> "$OUT/mirror.log"; git diff > "$OUT/after-mirror.diff"
cargo test -p acpmux --test hub_integration -- fork_restart transfer --nocapture > "$OUT/hub.log" 2>&1
tail -50 "$OUT"/*.log
exit 0
