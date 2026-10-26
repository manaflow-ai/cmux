#!/usr/bin/env bash
# pgo/lto-ab.sh (p08-startup task 110) without a build: the variants' xcconfigs are
# Release-only, the build modes refuse a non-fleet machine, and --table turns saved
# results into the table and verdicts (a faster variant is adopted, a Debug change or a
# missing flag fails the run).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ab="$here/../pgo/lto-ab.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/lto-ab-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# xcconfigs: base adds nothing, every other setting is [config=Release].
[[ -z "$("$ab" --print-xcconfig base | grep -v '^//' || true)" ]] || fail "base adds a setting"
for v in thinlto cmo; do
  settings="$("$ab" --print-xcconfig "$v" | grep -v '^//')"
  [[ -n "$settings" ]] || fail "$v adds no setting"
  if grep -v -F '[config=Release]' <<<"$settings"; then fail "$v has a setting outside Release"; fi
done
"$ab" --print-xcconfig thinlto | grep -q -F -- '-lto=llvm-thin' || fail "thinlto lacks Swift -lto=llvm-thin"
"$ab" --print-xcconfig thinlto | grep -q -F 'LLVM_LTO[config=Release] = YES_THIN' || fail "thinlto lacks LLVM_LTO"
"$ab" --print-xcconfig cmo | grep -q -F -- '-cross-module-optimization' || fail "cmo lacks -cross-module-optimization"
if "$ab" --print-xcconfig nope 2>/dev/null; then fail "an unknown variant was accepted"; fi

# A build run outside the fleet stops before building (exit 2).
rc=0
env -u CMUX_CI_STEP_KEY GITHUB_ACTIONS=false "$ab" --out "$work/refused" 2>"$work/err" || rc=$?
[[ "$rc" == 2 ]] || fail "a build run off the fleet exited $rc, not 2"
grep -q 'runs only on the build fleet' "$work/err" || fail "no fleet-only message"
[[ ! -e "$work/refused" ]] || fail "a refused run wrote its output folder"
rc=0
"$ab" --variants thinlto,cmo 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail "--variants without base exited $rc, not 2"

# Saved results: base, a faster thinlto, a cmo that changed Debug.
fixture() { # DIR CMO_DEBUG_COMPILES CMO_FLAGS
  local dir=$1 cmo_compiles=$2 cmo_flags=$3
  mkdir -p "$dir/typing"
  printf 'base\nthinlto\ncmo\n' >"$dir/variants.txt"
  {
    printf 'run\tsha\tabc123\nrun\txcode\tXcode 26.6\nrun\thost\tmini-1\nrun\tcold\tpurged\n'
    for v in base thinlto cmo; do
      printf '%s\tstatus\tok\n%s\tbuild_s\t600\n%s\tlink_s\t12.5\n' "$v" "$v" "$v"
      printf '%s\texe_bytes\t150000000\n%s\ttext_bytes\t90000000\n%s\tapp_kb\t400000\n' "$v" "$v" "$v"
      printf '%s\tdebug_leaf_s\t20\n%s\tdebug_flag_hits\t0\n' "$v" "$v"
    done
    printf 'base\tflags\tapplied\nthinlto\tflags\tapplied\ncmo\tflags\t%s\n' "$cmo_flags"
    printf 'base\tdebug_swift_compiles\t1\nthinlto\tdebug_swift_compiles\t1\ncmo\tdebug_swift_compiles\t%s\n' "$cmo_compiles"
  } >"$dir/facts.tsv"
  /usr/bin/env python3 -I - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
def runs(start):
    return [{"first_window_frame_committed": start + i} for i in range(10)]
json.dump({"ltoab-base": {"cold": runs(400), "warm": runs(200)},
           "ltoab-thinlto": {"cold": runs(340), "warm": runs(170)},
           "ltoab-cmo": {"cold": runs(399), "warm": runs(200)}}, open(os.path.join(d, "startup.json"), "w"))
for v, p95 in (("base", 8.0), ("thinlto", 8.1), ("cmo", 8.0)):
    for r in (1, 2, 3):
        os.makedirs(os.path.join(d, "typing", f"{v}-{r}"))
        json.dump({"phases": {"single": {"stats": {"key_to_frame_ms": {"p95": p95}}}}},
                  open(os.path.join(d, "typing", f"{v}-{r}", "report.json"), "w"))
PY
}

fixture "$work/good" 1 applied
"$ab" --table "$work/good" >"$work/good.out" || fail "a complete run exited non-zero"
grep -q '^| thinlto | ok | applied |.*| adopt (cold/warm first frame faster) |$' "$work/good.out" \
  || fail "the faster thinlto was not adopted: $(cat "$work/good.out")"
grep -q '^| cmo | ok | applied |.*| keep base: no first-frame win |$' "$work/good.out" || fail "cmo verdict"
grep -q '^| base |.*| reference |$' "$work/good.out" || fail "base row"
grep -q -F '344 (-14.8 %)' "$work/good.out" || fail "the cold p50 change is not shown: $(cat "$work/good.out")"
[[ -s "$work/good/table.md" && -s "$work/good/results.json" ]] || fail "table.md or results.json missing"

fixture "$work/debug" 240 applied
rc=0
"$ab" --table "$work/debug" >"$work/debug.out" 2>"$work/debug.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a Debug change exited $rc, not 1"
grep -q 'cmo: Debug changed' "$work/debug.err" || fail "the Debug change was not named"
grep -q '^| cmo |.*| keep base: Debug changed |$' "$work/debug.out" || fail "cmo with Debug changed was not kept off"

fixture "$work/flags" 1 "missing -cross-module-optimization"
rc=0
"$ab" --table "$work/flags" >"$work/flags.out" 2>"$work/flags.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a missing flag exited $rc, not 1"
grep -q '^| cmo |.*| incomplete |$' "$work/flags.out" || fail "a variant without its flags was not incomplete"

echo "lto-ab.test.sh: ok"
