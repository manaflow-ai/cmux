#!/usr/bin/env bash
# The p10 done checks in one table (plans/cmux-next/chrome-parity/p10-stability.md, section 5).
#
#   scripts/cmux-next/stability-final.sh [--artifacts DIR]
#
# One row per measured part of a done check: check number, what, value, target, ok, command. Tree counts
# come from git grep, jq and crash_ratchet.py's closure scan (about 30 s); run results come from the
# artifacts the lead saves from the final-tip runs, in DIR (default $CMUX_STABILITY_ARTIFACTS or
# artifacts/stability-final):
#
#   swift-diagnostics.jsonl   swift-diagnostics.sh --out (one diagnostic per line, with "group")
#   trap-classify.json        crash_ratchet.py --report trap_api,index_subscript,int_conversion --classify --json
#   rust-panic*.json          rust_panic_ratchet.py --clippy-json linux=.. --clippy-json macos=.. --report json
#   clippy-*.jsonl            the Q10 clippy runs (for undocumented_unsafe_blocks)
#   async-blocking-scan.json  async-blocking-scan --root cmux-tui/crates --json
#   cef-shim-warnings.txt     the warning file of build-cef-shim.sh
#   sanitizer-swift/          sanitizer-sweep.sh --out sanitizer-swift/findings.jsonl (with its summary.json)
#   sanitizer-rust/           cmux-tui/scripts/sanitize.sh --out sanitizer-rust/findings.jsonl
#   rust-fuzz/summary.jsonl   rust-fuzz.sh --out rust-fuzz (30 min per target)
#   soak/, soak-asan/         readiness-soak.py --out (report.json)
#   stability-sig.json        gh issue list -l stability-sig --state open --json number,createdAt,closedByPullRequestsReferences
#   health.json               stability-health.py --env nightly-next --days 3 --json (else run live with SENTRY_AUTH_TOKEN)
#   exits/NAME.exit           the exit status of each command the table lists as "exit of NAME"
#
# Other-owner rows (stability-other-owners.json, health.json's other_owner) are printed apart and do not
# count. Read-only: it writes no file (python runs with -B). Exit 0 only when every row meets its target,
# 1 otherwise (a missing artifact misses its target), 2 on a bad argument.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ART="${CMUX_STABILITY_ARTIFACTS:-$ROOT/artifacts/stability-final}"
case "${1:-}" in
  --artifacts) ART="${2:?--artifacts needs a folder}" ;;
  "") ;;
  *) sed -n '2,4p' "$0" >&2; exit 2 ;;
esac
cd "$ROOT" || exit 2
S=scripts/cmux-next
MISSES=0

# row CHECK WHAT VALUE OP TARGET COMMAND: OP is <=, >= or = (a string target compares as text).
row() {
  local ok=no
  if [[ $3 =~ ^-?[0-9]+(\.[0-9]+)?$ && $5 =~ ^-?[0-9.]+$ ]]; then
    awk -v v="$3" -v t="$5" -v op="$4" 'BEGIN { exit !((op == "<=" && v <= t) || (op == ">=" && v >= t) || (op == "=" && v == t)) }' && ok=yes
  elif [[ $4 == "=" && $3 == "$5" ]]; then ok=yes; fi
  [[ $ok == yes ]] || MISSES=$((MISSES + 1))
  printf '%-4s %-62s %10s %-9s %-3s %s\n' "$1" "$2" "$3" "$4 $5" "$ok" "$6"
}
lines() { git grep -n "$@" | wc -l | tr -d ' '; }
# jqa FILE FILTER [jq args]: the filter's value on an artifact, or "missing".
jqa() { local f="$ART/$1"; shift; [[ -s $f ]] && jq -r "$@" "$f" 2>/dev/null || echo missing; }
exit_of() { local f="$ART/exits/$1.exit"; [[ -s $f ]] && tr -d '[:space:]' <"$f" || echo missing; }
exit_row() { row "$1" "exit of $2" "$(exit_of "$2")" = 0 "$3"; }
# unmarked PATTERN MARKER -- PATHSPEC...: hits with MARKER on neither the line nor the 2 lines above.
unmarked() {
  local pattern=$1 marker=$2; shift 3
  git grep -n -B2 -E "$pattern" -- "$@" | awk -v p="$pattern" -v m="$marker" '
    /^--$/ { a = b = ""; next }
    $0 ~ p && index($0 a b, m) == 0 { n++ }
    { a = b; b = $0 } END { print n + 0 }'
}

SCAN=()
while IFS= read -r line; do SCAN+=("$line"); done < <(python3 -B -c '
import sys; sys.path.insert(0, sys.argv[1]); import crash_ratchet as c
s = c.Scan(); c.scan_swift(".", s, False)
print(sum(s.counts["swift"].get("unchecked", {}).values())); print(sum(s.waived["swift"].get("unchecked", {}).values()))
print("\n".join(c.swift_source_roots(".")))' "$S")
[[ ${#SCAN[@]} -ge 3 ]] || { echo "stability-final: crash_ratchet.py closure scan failed" >&2; exit 1; }
ROOTS=("${SCAN[@]:2}")
SWIFT=("${ROOTS[@]/%//*.swift}")
MANIFESTS=("${ROOTS[@]/%\/Sources/\/Package.swift}")
EXTERNAL=(Packages/macOS/CmuxNext/Sources/CmuxNext{Daemon,Control,Mobile,MobileHost,Phone,RemoteView,BrowserImport}/
  Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/ Packages/Shared/Cmux{IrohTransport,IrxTransport,VNC,VNCWebRTC,ScreenKit}/Sources/)
FFI=(cmux-tui/crates/{cmux-app-ffi,cmux-rd-ffi,cmux-layout-reducer-ffi,cmux-palette-ranker}/src)

printf '%-4s %-62s %10s %-9s %-3s %s\n' "#" "row" "value" "target" "ok" "command"
row 1 "swiftLanguageMode(.v5) in closure manifests" "$(lines -F 'swiftLanguageMode(.v5)' -- "${MANIFESTS[@]}")" = 0 "git grep swiftLanguageMode(.v5) -- <closure Package.swift>"
row 2 "@unchecked Sendable / nonisolated(unsafe) in the closure" "$((SCAN[0] + SCAN[1]))" "<=" 30 "crash_ratchet.py scan: swift.unchecked counted + waived"
row 2 "... of them without crash-allow" "${SCAN[0]}" = 0 "crash_ratchet.py scan: swift.unchecked counted"
row 3 "@preconcurrency in the closure (not SparkleSeam)" "$(git grep -n '@preconcurrency' -- "${SWIFT[@]}" | grep -vc SparkleSeam)" = 0 "git grep @preconcurrency -- <closure Sources>"
missing_safety=0
for m in "${MANIFESTS[@]}"; do
  grep -qE '\.(target|executableTarget|testTarget)\(' "$m" 2>/dev/null || continue
  grep -q 'strictMemorySafety()' "$m" && grep -q 'treatWarning("StrictMemorySafety", as: .error)' "$m" || missing_safety=$((missing_safety + 1))
done
row 4 "closure manifests without strict memory safety as error" "$missing_safety" = 0 "grep strictMemorySafety() + treatWarning(StrictMemorySafety) <closure Package.swift>"
row 4 "StrictMemorySafety diagnostics" "$(jqa swift-diagnostics.jsonl -s '[.[] | select(.group == "StrictMemorySafety")] | length')" = 0 "swift-diagnostics.sh --summary --group StrictMemorySafety"
row 4 "SAFETY-TODO(p10) in external-input modules" "$(lines -F 'SAFETY-TODO(p10)' -- "${EXTERNAL[@]}")" = 0 "git grep SAFETY-TODO(p10) -- <Daemon Control Mobile ... Browser/CEF>"
row 5 "raw continuations outside CmuxSafeConcurrency" "$(lines -E 'with(Checked|Unsafe)(Throwing)?Continuation' -- 'Packages/**/Sources/**/*.swift' ':!Packages/Shared/CmuxSafeConcurrency')" = 0 "git grep with(Checked|Unsafe)(Throwing)?Continuation"
row 5 "hand-written once guards" "$(lines -E '(class|struct) (ResumeOnce|Once|OnceBox|ResumeGuard|InstallOnce|AgentPaneResumeOnce)\b' -- 'Packages/**/Sources')" = 0 "git grep '(class|struct) (ResumeOnce|Once|...)'"
row 6 "swift.unowned allowlist entries without lifetime:" "$(jq '[.allow[] | select(.class == "swift.unowned" and ((.reason // "") | contains("lifetime:") | not))] | length' $S/crash-allowlist.json)" = 0 "jq crash-allowlist.json"
row 6 "swift.unowned allowlist count" "$(jq '[.allow[] | select(.class == "swift.unowned") | .count // 1] | add // 0' $S/crash-allowlist.json)" "<=" 20 "jq crash-allowlist.json"
row 6 "Unmanaged.passUnretained outside CallbackRegistry" "$(lines -F 'Unmanaged.passUnretained' -- 'Packages/**/Sources/**/*.swift' ':(exclude,glob)Packages/Shared/CmuxSafeConcurrency/**/CallbackRegistry*.swift')" = 0 "git grep Unmanaged.passUnretained"
row 7 "input-reachable trap sites" "$(jqa trap-classify.json '[.. | objects | select(.class? == "input")] | length')" = 0 "crash_ratchet.py --report trap_api,index_subscript,int_conversion --classify"
row 7 "uniqueKeysWithValues" "$(lines -F uniqueKeysWithValues -- 'Packages/**/Sources')" = 0 "git grep uniqueKeysWithValues"
row 7 "raising FileHandle reads" "$(lines -E 'availableData|seekToEndOfFile\(\)|readData\(ofLength' -- 'Packages/**/Sources')" = 0 "git grep availableData|seekToEndOfFile()|readData(ofLength"
row 7 "Invariant.check / dumpWillBeCheck sites without allowlist entry" "$(exit_of invariant-allowlist)" = 0 "exit of invariant-allowlist: crash_ratchet.py --report invariant_check"
panic_crates=missing
compgen -G "$ART/rust-panic*.json" >/dev/null && panic_crates="$(jq -s '[.[] | to_entries[] | select(.value.deny | not)] | length' "$ART"/rust-panic*.json 2>/dev/null || echo missing)"
row 8 "Rust crates with a deny-lint hit (Linux + macOS)" "$panic_crates" = 0 "rust_panic_ratchet.py --clippy-json linux=.. --clippy-json macos=.. --report json"
exports="$(lines -F 'extern "C" fn' -- "${FFI[@]}")"
guarded="$(lines -E 'ffi_boundary\(|ffi-nopanic:' -- "${FFI[@]}")"
row 9 "FFI exports without ffi_boundary or ffi-nopanic" "$((exports - guarded))" "<=" 0 "git grep 'extern \"C\" fn' vs 'ffi_boundary(|ffi-nopanic:' -- <4 FFI crates>"
pin="$(grep -oE 'cmux-app-ffi-[0-9a-f]{40}' Packages/macOS/CmuxNext/Package.swift | head -n 1)"; pin="${pin#cmux-app-ffi-}"
pin_missing=0
for task in 152 156; do
  commit="$(git log -1 --format=%H --grep="p10-stability-$task" HEAD)"
  [[ -n $commit && -n $pin ]] && git merge-base --is-ancestor "$commit" "$pin" 2>/dev/null || pin_missing=$((pin_missing + 1))
done
row 9 "tasks 152 and 156 missing from the CCmuxAppFFI pin" "$pin_missing" = 0 "git merge-base --is-ancestor <task commit> <pin source sha>"
exit_row 9 check-app-ffi-pin "scripts/cmux-next/check-app-ffi-pin.sh"
row 10 "async-blocking-scan findings" "$(jqa async-blocking-scan.json 'if type == "array" then length else ([.findings[]?] | length) end')" = 0 "cargo run --manifest-path cmux-tui/tools/async-blocking-scan/Cargo.toml -- --root cmux-tui/crates --json"
exit_row 10 lab-clippy-disallowed "CLIPPY_CONF_DIR=cmux-tui/lab/clippy cargo clippy (0 disallowed_methods outside cmux-blocking)"
undocumented=missing
compgen -G "$ART/clippy-*.jsonl" >/dev/null && undocumented="$(cat "$ART"/clippy-*.jsonl | grep -c 'clippy::undocumented_unsafe_blocks')"
row 11 "undocumented_unsafe_blocks" "$undocumented" = 0 "Q10 clippy runs: clippy::undocumented_unsafe_blocks"
row 11 "unsafe impl Send/Sync without SAFETY" "$(unmarked 'unsafe impl.*(Send|Sync) for' SAFETY -- 'cmux-tui/crates/*/src' 'Native' 'cmux-next-ios/rust')" = 0 "git grep -B2 'unsafe impl .. (Send|Sync)'"
row 12 "-Wunsafe-buffer-usage warnings in the CEF shim" "$(jqa cef-shim-warnings.txt -R -s '[splits("\n") | select(test("-Wunsafe-buffer-usage"))] | length')" = 0 "build-cef-shim.sh warning file"
flags=0
for f in -Werror=unsafe-buffer-usage _LIBCPP_HARDENING_MODE_FAST -ftrivial-auto-var-init=pattern -fstack-protector-strong; do grep -qF -e "$f" $S/build-cef-shim.sh || flags=$((flags + 1)); done
row 12 "hardening flags missing from build-cef-shim.sh" "$flags" = 0 "grep <4 flags> scripts/cmux-next/build-cef-shim.sh"
swift_san="$(jqa sanitizer-swift/summary.json 'if .complete then "complete" else "incomplete" end')"
[[ $swift_san == complete && -f $ART/sanitizer-swift/findings.jsonl ]] && swift_san="$(grep -c . "$ART/sanitizer-swift/findings.jsonl")"
row 13 "Swift sanitizer findings (thread,address,undefined,coop-strict)" "$swift_san" = 0 "sanitizer-sweep.sh --sanitize thread,address,undefined,coop-strict --ref SHA"
row 13 "reasoned TSan suppressions" "$(grep -cv -E '^[[:space:]]*(#|$)' $S/tsan-suppressions.txt)" "<=" 10 "grep -cv comments scripts/cmux-next/tsan-suppressions.txt"
rust_san=missing; [[ -f $ART/sanitizer-rust/findings.jsonl ]] && rust_san="$(grep -c . "$ART/sanitizer-rust/findings.jsonl")"
row 14 "Rust sanitizer and Miri findings" "$rust_san" = 0 "cmux-tui/scripts/sanitize.sh --sanitizer address,thread,leak"
exit_row 14 loom-holder-ring "loom test of the holder ring"
row 15 "Rust fuzz targets" "$(git ls-files 'cmux-tui/fuzz/fuzz_targets/*.rs' 'Native/DiffSidecar/fuzz/fuzz_targets/*.rs' 'Native/OptChat/fuzz/fuzz_targets/*.rs' 'cmux-next-ios/rust/fuzz/fuzz_targets/*.rs' | wc -l | tr -d ' ')" ">=" 40 "git ls-files '*/fuzz/fuzz_targets/*.rs'"
row 15 "Swift suites on CmuxFuzzSupport" "$(git grep -l 'import CmuxFuzzSupport' -- 'Packages/**/Tests/**/*.swift' | wc -l | tr -d ' ')" ">=" 25 "git grep -l 'import CmuxFuzzSupport' -- 'Packages/**/Tests'"
exit_row 15 swift-libfuzzer "the >= 6 coverage-guided Swift libFuzzer targets, 30 min each, 0 crashes"
row 15 "Rust fuzz runs with a crash, OOM, timeout or leak" "$(jqa rust-fuzz/summary.jsonl -s '[.[] | select(.verdict != "clean")] | length')" = 0 "rust-fuzz.sh --out DIR (-rss_limit_mb=2048 -malloc_limit_mb=256 -timeout=2)"
row 15 "shortest Rust fuzz run (s)" "$(jqa rust-fuzz/summary.jsonl -s 'if length == 0 then "missing" else (map(.seconds) | min) end')" ">=" 1800 "rust-fuzz.sh summary.jsonl seconds"
exit_row 16 os-matrix-fuzz "os-matrix.sh --build JOB --os 14,15,26,27 --suite fuzz --minutes 60 (x 4 seeds)"
exit_row 16 os-matrix-chaos "os-matrix.sh --build JOB --os 14,15,26,27 --suite chaos"
for name in process-chaos-e2e process-chaos-gpu-crash-loop child-crash-e2e crash-ends-app-gate state-corruption-e2e; do
  exit_row 17 "$name" "$name.py on the final tip (bare metal)"
done
exit_row 18 hang-scope-tests "HangWatchScope tests: 0 kevent per scope, blocked-scope top frame"
exit_row 18 rust-watch-scope-tests "cmux-panic-log watch_scope tests: blocked-scope top frame"
exit_row 18 bench-idle-wakeups "bench-idle wakeups unchanged before/after task 031"
coverage="$(python3 -B $S/stability-lab.py coverage --since 72h --json 2>/dev/null | jq -r '.summary.percent' 2>/dev/null)"
row 19 "landed commits in a tip that passed the fast lanes (%)" "${coverage:-error}" ">=" 100 "stability-lab.py coverage --since 72h"
owned="$(jq -r '[.owners[].github_issue] | map(tostring) | join(",")' $S/stability-other-owners.json)"
row 19 "stability-sig issues > 24 h old with no fix in review" "$(jqa stability-sig.json --arg owned "$owned" '[.[] | select((.createdAt | fromdateiso8601) < (now - 86400)
  and ((.closedByPullRequestsReferences // []) | length) == 0 and ((.number | tostring) as $n | $owned | split(",") | index($n) | not))] | length')" = 0 "gh issue list -l stability-sig --state open"
row 20 "24 h soak, 10 agents, bare metal" "$(jqa soak/report.json 'if .ok then "ok" else "failed" end')" = ok "readiness-soak.py --hours 24 --agents 10"
row 20 "6 h ASan soak, Chromium off" "$(jqa soak-asan/report.json 'if .ok then "ok" else "failed" end')" = ok "readiness-soak.py --hours 6 --app-config asan"
health="$(cat "$ART/health.json" 2>/dev/null)"
[[ -z $health && -n ${SENTRY_AUTH_TOKEN:-} ]] && health="$(python3 -B $S/stability-health.py --env nightly-next --days 3 --json 2>/dev/null)"
if jq -e '.checks' >/dev/null 2>&1 <<<"$health"; then
  while IFS=$'\t' read -r name value op target; do
    row 21 "$name" "$value" "$op" "$target" "stability-health.py --env nightly-next --days 3"
  done < <(jq -r '.checks[] | [.name, (.value // "n/a" | tostring), .op, (.target | tostring)] | @tsv' <<<"$health")
else
  row 21 "field stability (stability-health.py)" missing = ok "stability-health.py --env nightly-next --days 3 --json"
fi

printf '\nOther-owner rows (not counted; checks 16 and 21)\n'
jq -r '.owners[] | "  \(.owner)  #\(.github_issue)  ETA: \(.eta)"' $S/stability-other-owners.json
[[ -n $health ]] && jq -r '.other_owner[]? | "  \(.owner)  #\(.github_issue)  hang events \(.hang_events), issue events \(.issue_events): \(.issues | join(" "))"' <<<"$health" 2>/dev/null
printf '\n%s\n' "$([[ $MISSES -eq 0 ]] && echo "STABILITY FINAL: PASS" || echo "STABILITY FINAL: FAIL ($MISSES rows miss their target)")"
[[ $MISSES -eq 0 ]]
