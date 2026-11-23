#!/usr/bin/env bash
# run-v2-gates.sh marks the lines a failed gate filter appended to V2_GATE_OUT
# with "gate_failed":true, so the v2 home reads those rows red with their
# numbers kept. A stand-in cargo on PATH plays three filters: one writes a line
# and fails, one writes a line and passes, one fails having written nothing.
# The script's exit code stays the one it had (1 when any filter failed). A
# stand-in bun records the page group's lines, which start webviews/bench/v2-gate.ts.
# With an argument, the measures file is copied there for the home's test
# (benches/v2/mod.rs reads it through report_value).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
# The filter is the word after --lib, or after --test and its binary.
while [[ $# -gt 0 && $1 != --lib && $1 != --test ]]; do shift; done
[[ ${1:-} == --test ]] && shift
filter=${2:-}
line() { printf '{"name":"%s","small_p95":1000,"god_p95":1100,"god_p95_all":1200,"unit":"ns"}\n' "$1" >>"$V2_GATE_OUT"; }
case $filter in
  kin_table_change_gate) line v2.pr05e.kin_table_change; echo "assertion failed" >&2; exit 101 ;;
  sibling_insert_gate) line v2.pr05e.sibling_insert ;;
  family_page_gate) exit 101 ;;
esac
exit 0
CARGO
chmod +x "$TMP/bin/cargo"

# A stand-in bun for the page group: the webviews pin for the version check, else it records the
# entry script and filter it was started with and writes nothing.
pin=$(python3 -I "$ROOT/scripts/webviews_bun_version.py" "$ROOT/webviews/package.json")
cat >"$TMP/bin/bun" <<BUN
#!/usr/bin/env bash
if [[ \${1:-} == --version ]]; then echo "$pin"; exit 0; fi
echo "\${1#"$ROOT/"} \${2:-}" >>"$TMP/bun.args"
BUN
chmod +x "$TMP/bin/bun"

out="$TMP/v2-measures.ndjson"
status=0
(cd "$TMP" && PATH="$TMP/bin:$PATH" V2_GATE_OUT="$out" "$ROOT/scripts/cmux-next/run-v2-gates.sh" >"$TMP/log" 2>&1) || status=$?
[[ $status -eq 1 ]] || fail "the script exited $status, not 1, with failed filters" "$(cat "$TMP/log")"
[[ $(wc -l <"$out") -eq 2 ]] || fail "expected two measure lines" "$(cat "$out")"
grep -qx '{"name":"v2.pr05e.kin_table_change",.*,"unit":"ns","gate_failed":true}' "$out" \
  || fail "the failed filter's line is not marked" "$(cat "$out")"
grep -qx '{"name":"v2.pr05e.sibling_insert",.*,"unit":"ns"}' "$out" \
  || fail "the passing filter's line changed" "$(cat "$out")"
python3 -I -c 'import json, sys; [json.loads(line) for line in open(sys.argv[1])]' "$out" \
  || fail "a marked line is not JSON" "$(cat "$out")"

# The page group starts the entry script once per pr06.gates page line, in line order.
expected=$'webviews/bench/v2-gate.ts page_store_apply\nwebviews/bench/v2-gate.ts page_store_text\nwebviews/bench/v2-gate.ts page_store_held'
[[ "$(cat "$TMP/bun.args" 2>/dev/null)" == "$expected" ]] \
  || fail "the page group did not run its lines" "$(cat "$TMP/bun.args" 2>/dev/null)" "$(cat "$TMP/log")"
grep -q '^v2 gate group page: ' "$TMP/log" || fail "no page group timing line" "$(cat "$TMP/log")"

if [[ $# -gt 0 ]]; then cp "$out" "$1"; fi
echo "run-v2-gates.test.sh: ok"
