#!/usr/bin/env bash
# run-v2-gates.sh marks the lines a failed gate filter appended to V2_GATE_OUT
# with "gate_failed":true, so the v2 home reads those rows red with their
# numbers kept. A stand-in cargo on PATH plays three filters: one writes a line
# and fails, one writes a line and passes, one fails having written nothing.
# The script's exit code stays the one it had (1 when any filter failed), and
# the filter that wrote nothing is named in its log. A bad gate line exits 2 by
# name, and the script uses no bash 4 construct.
# With an argument, the measures file is copied there for the home's test
# (benches/v2/mod.rs reads it through report_value).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
# Each call goes to CARGO_CALLS. A group's build step (the filter no test matches) of the
# target STUB_BROKEN names fails, as a compile error does.
printf '%s\n' "$*" >>"$CARGO_CALLS"
args="$*"
while [[ $# -gt 0 && $1 != --lib && $1 != --test ]]; do shift; done
[[ ${1:-} == --test ]] && shift
filter=${2:-}
line() { printf '{"name":"%s","small_p95":1000,"god_p95":1100,"god_p95_all":1200,"unit":"ns"}\n' "$1" >>"$V2_GATE_OUT"; }
case $filter in
  v2_gates_build_only_no_test_matches)
    [[ -n ${STUB_BROKEN:-} && $args == *"$STUB_BROKEN"* ]] && { echo "error[E0063]: stub" >&2; exit 101; } ;;
  kin_table_change_gate) line v2.pr05e.kin_table_change; echo "assertion failed" >&2; exit 101 ;;
  sibling_insert_gate) line v2.pr05e.sibling_insert ;;
  family_page_gate) exit 101 ;;
esac
exit 0
CARGO
chmod +x "$TMP/bin/cargo"

out="$TMP/v2-measures.ndjson"
export CARGO_CALLS="$TMP/calls"
status=0
(cd "$TMP" && PATH="$TMP/bin:$PATH" V2_GATE_OUT="$out" "$ROOT/scripts/cmux-next/run-v2-gates.sh" >"$TMP/log" 2>&1) || status=$?
# A group builds its target once before its filters run.
[[ $(grep -c -- '-p acpmux-book --lib v2_gates_build_only_no_test_matches ' "$CARGO_CALLS") -eq 1 ]] \
  || fail "book did not build exactly once" "$(cat "$CARGO_CALLS")"
[[ $(grep -n -- '-p acpmux-book --lib' "$CARGO_CALLS" | head -1) == *v2_gates_build_only_no_test_matches* ]] \
  || fail "book ran a gate before its build" "$(cat "$CARGO_CALLS")"
[[ $status -eq 1 ]] || fail "the script exited $status, not 1, with failed filters" "$(cat "$TMP/log")"
[[ $(wc -l <"$out") -eq 2 ]] || fail "expected two measure lines" "$(cat "$out")"
grep -qx '{"name":"v2.pr05e.kin_table_change",.*,"unit":"ns","gate_failed":true}' "$out" \
  || fail "the failed filter's line is not marked" "$(cat "$out")"
grep -qx '{"name":"v2.pr05e.sibling_insert",.*,"unit":"ns"}' "$out" \
  || fail "the passing filter's line changed" "$(cat "$out")"
python3 -I -c 'import json, sys; [json.loads(line) for line in open(sys.argv[1])]' "$out" \
  || fail "a marked line is not JSON" "$(cat "$out")"
grep -q '^v2 gates: failed before writing a measure: cargo test .* family_page_gate ' "$TMP/log" \
  || fail "the filter that wrote nothing is not named" "$(cat "$TMP/log")"
[[ $(grep -c '^v2 gates: failed before writing a measure:' "$TMP/log") -eq 1 ]] \
  || fail "a filter that wrote its line is named as writing none" "$(cat "$TMP/log")"

# A group that does not build runs none of its gates, once: one compile error in a group
# rebuilt per filter spent the nightly's whole gate budget (run 45413199195). Its gates are
# named in one line, the other groups still run, and the script exits 1.
: >"$CARGO_CALLS"
broken_out="$TMP/broken.ndjson"
status=0
(cd "$TMP" && PATH="$TMP/bin:$PATH" V2_GATE_OUT="$broken_out" STUB_BROKEN="-p acpmux-book" \
  "$ROOT/scripts/cmux-next/run-v2-gates.sh" >"$TMP/log" 2>&1) || status=$?
[[ $status -eq 1 ]] || fail "a group that does not build exited $status, not 1" "$(cat "$TMP/log")"
[[ $(grep -c -- '-p acpmux-book' "$CARGO_CALLS") -eq 1 ]] \
  || fail "a group that does not build ran more than its build" "$(cat "$CARGO_CALLS")"
grep -q '^v2 gates: group book does not build; its gates did not run:.* family_page_gate' "$TMP/log" \
  || fail "the group that does not build is not named with its gates" "$(cat "$TMP/log")"
grep -q -- '-p acpmux-core --lib v2_gates_build_only_no_test_matches ' "$CARGO_CALLS" \
  || fail "a later group did not run after one that does not build" "$(cat "$CARGO_CALLS")"
[[ ! -s $broken_out ]] || fail "a group that does not build wrote rows" "$(cat "$broken_out")"

# A line of another shape or an unknown group fails the script by name, before any
# gate runs. A filter is a word of [A-Za-z0-9_]: `core mod::gate` is refused, and
# the registry tests' gate_lines() refuses it the same way.
mkdir -p "$TMP/bad/v2-gates.d"
cp "$ROOT/scripts/cmux-next/run-v2-gates.sh" "$TMP/bad/"
for bad in 'core mod::gate' 'core two words' 'acpmux-core some_gate'; do
  printf '%s\n' "$bad" >"$TMP/bad/v2-gates.d/pr99.gates"
  status=0
  (cd "$TMP" && PATH="$TMP/bin:$PATH" V2_GATE_OUT="$TMP/bad/out" bash "$TMP/bad/run-v2-gates.sh" >"$TMP/log" 2>&1) || status=$?
  [[ $status -eq 2 ]] || fail "the line '$bad' exited $status, not 2" "$(cat "$TMP/log")"
  grep -q 'pr99.gates:1: ' "$TMP/log" || fail "the line '$bad' is not named" "$(cat "$TMP/log")"
  [[ ! -e $TMP/bad/out ]] || fail "a gate ran with the line '$bad'"
done

# The script keeps to bash 3.2, a Mac's stock bash.
if grep -nE '(declare|local|typeset) -[a-zA-Z]*A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' \
  "$ROOT/scripts/cmux-next/run-v2-gates.sh"; then
  fail "run-v2-gates.sh uses a bash 4 construct"
fi

if [[ $# -gt 0 ]]; then cp "$out" "$1"; fi
echo "run-v2-gates.test.sh: ok"
