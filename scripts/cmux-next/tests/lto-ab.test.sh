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
fixture() { # DIR CMO_DEBUG_COMPILES CMO_FLAGS [DEBUG: ran|skipped|unmarked]
  local dir=$1 cmo_compiles=$2 cmo_flags=$3 debug=${4:-ran}
  mkdir -p "$dir/typing"
  printf 'base\nthinlto\ncmo\n' >"$dir/variants.txt"
  {
    printf 'run\tsha\tabc123\nrun\txcode\tXcode 26.6\nrun\thost\tmini-1\nrun\tcold\tpurged\n'
    [[ "$debug" == unmarked ]] || printf 'run\tdebug\t%s\n' "$debug"
    for v in base thinlto cmo; do
      printf '%s\tstatus\tok\n%s\tbuild_s\t600\n%s\tlink_s\t12.5\n' "$v" "$v" "$v"
      printf '%s\texe_bytes\t150000000\n%s\ttext_bytes\t90000000\n%s\tapp_kb\t400000\n' "$v" "$v" "$v"
      [[ "$debug" != ran ]] || printf '%s\tdebug_leaf_s\t20\n%s\tdebug_flag_hits\t0\n' "$v" "$v"
    done
    printf 'base\tflags\tapplied\nthinlto\tflags\tapplied\ncmo\tflags\t%s\n' "$cmo_flags"
    [[ "$debug" != ran ]] ||
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

# Debug never ran (the cold build failed before any fact) and --skip-debug is not recorded:
# a problem, and the faster thinlto is not adopted.
fixture "$work/nodebug" 1 applied unmarked
rc=0
"$ab" --table "$work/nodebug" >"$work/nodebug.out" 2>"$work/nodebug.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a run with no Debug facts and no skip marker exited $rc, not 1"
grep -q 'thinlto: Debug leaf-edit numbers missing' "$work/nodebug.err" || fail "missing Debug was not named"
if grep -q 'adopt' "$work/nodebug.out"; then fail "a variant was adopted without Debug evidence"; fi

# A failed Debug cold build and a failed leaf edit are named.
fixture "$work/debugfail" 1 applied unmarked
printf 'run\tdebug\tran\nrun\tdebug_failed\tdebug-cold build failed\n' >>"$work/debugfail/facts.tsv"
rc=0
"$ab" --table "$work/debugfail" >/dev/null 2>"$work/debugfail.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a failed Debug cold build exited $rc, not 1"
grep -q 'Debug: debug-cold build failed' "$work/debugfail.err" || fail "the failed Debug build was not named"
fixture "$work/leaffail" 1 applied
printf 'thinlto\tdebug_failed\tdebug-leaf-thinlto build failed\n' >>"$work/leaffail/facts.tsv"
rc=0
"$ab" --table "$work/leaffail" >"$work/leaffail.out" 2>"$work/leaffail.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a failed Debug leaf edit exited $rc, not 1"
grep -q 'thinlto: Debug: debug-leaf-thinlto build failed' "$work/leaffail.err" || fail "the failed leaf edit was not named"
if grep -q '^| thinlto |.*adopt' "$work/leaffail.out"; then fail "thinlto was adopted after its Debug leaf edit failed"; fi

# --skip-debug: exit 0, but nothing is adopted without the Debug check.
fixture "$work/skipdebug" 1 applied skipped
"$ab" --table "$work/skipdebug" >"$work/skipdebug.out" || fail "a --skip-debug run exited non-zero"
grep -q '^| thinlto |.*| keep base: Debug not checked (--skip-debug) |$' "$work/skipdebug.out" \
  || fail "a --skip-debug run adopted thinlto: $(cat "$work/skipdebug.out")"

# A missing link time is a problem that says why.
fixture "$work/nolink" 1 applied
grep -v '^cmo	link_s	' "$work/nolink/facts.tsv" >"$work/nolink/facts.new"
printf 'cmo\tlink_problem\tthe relink ran no Ld for cmux\n' >>"$work/nolink/facts.new"
mv "$work/nolink/facts.new" "$work/nolink/facts.tsv"
rc=0
"$ab" --table "$work/nolink" >/dev/null 2>"$work/nolink.err" || rc=$?
[[ "$rc" == 1 ]] || fail "a missing link time exited $rc, not 1"
grep -q 'cmo: link time missing (the relink ran no Ld for cmux)' "$work/nolink.err" || fail "the link problem was not named"

# ThinLTO's -flto=thin counts only on the app executable's own Ld command, not on a clang
# compile that also says -o.
dd=/dd/Build/Intermediates.noindex/cmux.build/Release/cmux-next.build/Objects-normal
cat >"$work/compile-only.log" <<LOG
SwiftCompile normal arm64 (in target 'CmuxNextApp' from project 'CmuxNext')
    swiftc -module-name CmuxNextApp -O -lto=llvm-thin -c a.swift

CompileC /dd/abi.o /src/abi.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'CCuaDriverABI' from project 'CmuxComputerUseHelper')
    cd /src
    clang -x c -flto=thin -c /src/abi.c -o /dd/abi.o

Ld $dd/arm64/Binary/cmux normal arm64 (in target 'cmux-next' from project 'cmux')
    cd /src
    clang -Xlinker -dead_strip -filelist $dd/arm64/cmux.LinkFileList -o $dd/arm64/Binary/cmux

LOG
[[ "$("$ab" --check-flags thinlto "$work/compile-only.log" cmux)" == "missing -flto=thin" ]] \
  || fail "-flto=thin on a compile line only counted as applied"
sed 's/-dead_strip -filelist/-dead_strip -flto=thin -filelist/' "$work/compile-only.log" >"$work/linked.log"
[[ "$("$ab" --check-flags thinlto "$work/linked.log" cmux)" == applied ]] || fail "-flto=thin on the cmux Ld was not seen"
[[ "$("$ab" --check-flags base "$work/linked.log" cmux)" == "leaked -flto=thin" ]] || fail "base did not report a leaked flag"

# Link seconds come from the relink's Ld timing row, minus the no-op's, and need an Ld of
# the app executable in the relink and none in the no-op.
cat >"$work/noop.log" <<'LOG'
CreateUniversalBinary /dd/Build/Products/Release/cmux.app/Contents/MacOS/cmux normal arm64\ x86_64 (in target 'cmux-next' from project 'cmux')

Build Timing Summary
Ld (1 task) | 0.500 seconds
CodeSign (3 tasks) | 4.000 seconds
** BUILD SUCCEEDED **
LOG
cat >"$work/relink.log" <<LOG
Ld $dd/arm64/Binary/cmux normal arm64 (in target 'cmux-next' from project 'cmux')
    clang -filelist $dd/arm64/cmux.LinkFileList -o $dd/arm64/Binary/cmux

Ld $dd/x86_64/Binary/cmux normal x86_64 (in target 'cmux-next' from project 'cmux')
    clang -filelist $dd/x86_64/cmux.LinkFileList -o $dd/x86_64/Binary/cmux

Build Timing Summary
Ld (3 tasks) | 40.750 seconds
CodeSign (3 tasks) | 4.000 seconds
** BUILD SUCCEEDED **
LOG
[[ "$("$ab" --link-seconds "$work/relink.log" "$work/noop.log" cmux)" == 40.250 ]] \
  || fail "link seconds: $("$ab" --link-seconds "$work/relink.log" "$work/noop.log" cmux || true)"
rc=0
why="$("$ab" --link-seconds "$work/noop.log" "$work/noop.log" cmux)" || rc=$?
[[ "$rc" == 1 && "$why" == "the relink ran no Ld for cmux" ]] || fail "a relink without an Ld passed: $rc $why"
rc=0
why="$("$ab" --link-seconds "$work/relink.log" "$work/relink.log" cmux)" || rc=$?
[[ "$rc" == 1 && "$why" == *"no-op build linked cmux"* ]] || fail "a no-op that linked passed: $rc $why"
grep -v 'Build Timing Summary' "$work/relink.log" >"$work/relink-nosummary.log"
rc=0
"$ab" --link-seconds "$work/relink-nosummary.log" "$work/noop.log" cmux >/dev/null || rc=$?
[[ "$rc" == 1 ]] || fail "a relink without a timing summary passed"

echo "lto-ab.test.sh: ok"
