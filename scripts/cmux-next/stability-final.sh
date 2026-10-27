#!/usr/bin/env bash
# The p10 done checks in one table (plans/cmux-next/chrome-parity/p10-stability.md, section 5).
#
#   scripts/cmux-next/stability-final.sh [--artifacts DIR]
#
# One row per measured part of a done check: check number, what, value, target, ok, command. Tree counts
# come from git grep, jq, crash_ratchet.py's closure scan and stability_final_scan.py (about 30 s); run
# results come from the artifacts the lead saves from the final-tip runs, in DIR (default
# $CMUX_STABILITY_ARTIFACTS or artifacts/stability-final):
#
#   swift-diagnostics.jsonl   swift-diagnostics.sh --out (one diagnostic per line, with "group"; empty when clean)
#   trap-classify.json        crash_ratchet.py --report trap_api,index_subscript,int_conversion --all-modules --classify
#   objc-raises.json          crash_ratchet.py --report objc_raises
#   rust-panic*.json          rust_panic_ratchet.py --clippy-json linux=.. --clippy-json macos=.. --report json
#   clippy-report-NAME.jsonl  each lab clippy run made with `rust_panic_ratchet.py --report-flags` (CI's --flags
#   clippy-report-NAME.flags  never turns on undocumented_unsafe_blocks), and the flags that run was given
#   async-blocking-scan.json  async-blocking-scan --root cmux-tui/crates --json
#   cef-shim-warnings.txt     the warning file of build-cef-shim.sh (warning lines or one count; empty when clean)
#   sanitizer-swift/          sanitizer-sweep.sh --out sanitizer-swift/findings.jsonl (with its summary.json)
#   sanitizer-rust/           cmux-tui/scripts/sanitize.sh --out sanitizer-rust/findings-OS.jsonl
#                             --runs sanitizer-rust/runs-OS.jsonl, all four modes, on Linux and on macOS
#   rust-fuzz/summary.jsonl   rust-fuzz.sh --all --seconds 1800 --out rust-fuzz
#   process-chaos/*.jsonl     process-chaos-e2e.py --out: the full run and the --only gpu-crash-loop run
#   soak/, soak-asan/         readiness-soak.py --out (report.json)
#   stability-sig.json        gh issue list -l stability-sig --state open --limit 1000 --json number,createdAt
#   stability-sig-prs.json    gh pr list --state open --limit 1000 --json number,title,body,baseRefName (every base)
#   safety-todo-hour12.sha    the commit of the push's hour-12 tip (check 4: SAFETY-TODO(p10) then and now)
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
scan() { python3 -B $S/stability_final_scan.py "$@"; }
# jqa FILE FILTER [jq args]: the filter's value on a non-empty artifact, or "missing".
jqa() { local f="$ART/$1"; shift; [[ -s $f ]] && jq -r "$@" "$f" 2>/dev/null || echo missing; }
# jqe FILE FILTER [jq args]: as jqa, for an artifact whose clean state is an empty file (jq -s reads it as []).
jqe() { local f="$ART/$1"; shift; [[ -f $f ]] && jq -r "$@" "$f" 2>/dev/null || echo missing; }
exit_of() { local f="$ART/exits/$1.exit"; [[ -s $f ]] && tr -d '[:space:]' <"$f" || echo missing; }
exit_row() { row "$1" "exit of $2" "$(exit_of "$2")" = 0 "$3"; }
# count FILE PATTERN: lines of FILE that match PATTERN (0 when none).
count() { grep -c -e "$2" "$1"; }

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
ROOTS_JSON="$(printf '%s\n' "${ROOTS[@]}" | jq -R . | jq -s -c .)"
EXTERNAL=(Packages/macOS/CmuxNext/Sources/CmuxNext{Daemon,Control,Mobile,MobileHost,Phone,RemoteView,BrowserImport}/
  Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/ Packages/Shared/Cmux{IrohTransport,IrxTransport,VNC,VNCWebRTC,ScreenKit}/Sources/)
NOT_EXTERNAL=('Packages/**/Sources/**' "${EXTERNAL[@]/#/:(exclude)}")
# The modules of tasks 167-170 (objc_raises: JSONSerialization, legacy FileHandle, NSRange).
OBJC_MODULES='["CmuxNextAgentPane", "CmuxNextApp", "CmuxNextMobile", "CmuxNextHomeEngine", "CmuxNextBrowser",
  "CmuxNextCloud", "CmuxNextDaemon", "CmuxNextPages", "CmuxMobileRPC", "CmuxNextDiff", "CmuxNextNowPlaying",
  "CmuxNextPhone", "CmuxNextRemote", "MessagesLabHome", "CmuxNextDesign", "CmuxNextErrorJournal", "CmuxNextUpdater"]'

printf '%-4s %-62s %10s %-9s %-3s %s\n' "#" "row" "value" "target" "ok" "command"
row 1 "swiftLanguageMode(.v5) in closure manifests" "$(lines -F 'swiftLanguageMode(.v5)' -- "${MANIFESTS[@]}")" = 0 "git grep swiftLanguageMode(.v5) -- <closure Package.swift>"
row 2 "@unchecked Sendable / nonisolated(unsafe) in the closure" "$((SCAN[0] + SCAN[1]))" "<=" 30 "crash_ratchet.py scan: swift.unchecked counted + waived"
row 2 "... of them without crash-allow" "${SCAN[0]}" = 0 "crash_ratchet.py scan: swift.unchecked counted"
row 3 "@preconcurrency in the closure (not SparkleSeam)" "$(git grep -n '@preconcurrency' -- "${SWIFT[@]}" | grep -vc SparkleSeam)" = 0 "git grep @preconcurrency -- <closure Sources>"

row 4 "closure Swift targets without strict memory safety as error" "$(scan memory-safety)" = 0 "stability_final_scan.py memory-safety --list (stability-settings.json, per target)"
row 4 "closure manifests that differ from stability-settings.json" "$(scan settings-stale)" = 0 "apply-stability-settings.py --check"
row 4 "StrictMemorySafety diagnostics" "$(jqe swift-diagnostics.jsonl -s '[.[] | select(.group == "StrictMemorySafety")] | length')" = 0 "swift-diagnostics.sh --summary --group StrictMemorySafety"
row 4 "SAFETY-TODO(p10) in external-input modules" "$(lines -F 'SAFETY-TODO(p10)' -- "${EXTERNAL[@]}")" = 0 "git grep SAFETY-TODO(p10) -- <Daemon Control Mobile ... Browser/CEF>"
hour12="$(tr -d '[:space:]' 2>/dev/null <"$ART/safety-todo-hour12.sha")"
todo_now=missing todo_max=0
if [[ -n $hour12 ]] && git cat-file -e "$hour12^{commit}" 2>/dev/null; then
  todo_now="$(lines -F 'SAFETY-TODO(p10)' -- "${NOT_EXTERNAL[@]}")"
  todo_max="$(git grep -n -F 'SAFETY-TODO(p10)' "$hour12" -- "${NOT_EXTERNAL[@]}" | wc -l | awk '{ print $1 / 10 }')"
fi
row 4 "SAFETY-TODO(p10) elsewhere (<= 10 % of the hour-12 count)" "$todo_now" "<=" "$todo_max" "git grep SAFETY-TODO(p10) -- <other Sources>, now and at safety-todo-hour12.sha"

row 5 "raw continuations outside CmuxSafeConcurrency" "$(lines -E 'with(Checked|Unsafe)(Throwing)?Continuation' -- 'Packages/**/Sources/**/*.swift' ':!Packages/Shared/CmuxSafeConcurrency')" = 0 "git grep with(Checked|Unsafe)(Throwing)?Continuation"
row 5 "hand-written once guards" "$(lines -E '(class|struct) (ResumeOnce|Once|OnceBox|ResumeGuard|InstallOnce|AgentPaneResumeOnce)\b' -- 'Packages/**/Sources/**')" = 0 "git grep '(class|struct) (ResumeOnce|Once|...)'"
row 5 "raw-continuation rule in the local guardrails" "$(python3 -B $S/guardrails.py --list 2>/dev/null | grep -c '^raw-continuation:')" = 1 "guardrails.py --list"

row 6 "swift.unowned allowlist entries without lifetime:" "$(jq '[.allow[] | select(.class == "swift.unowned" and ((.reason // "") | contains("lifetime:") | not))] | length' $S/crash-allowlist.json)" = 0 "jq crash-allowlist.json"
row 6 "swift.unowned allowlist count" "$(jq '[.allow[] | select(.class == "swift.unowned") | .count // 1] | add // 0' $S/crash-allowlist.json)" "<=" 20 "jq crash-allowlist.json"
row 6 "Unmanaged.passUnretained outside CallbackRegistry" "$(lines -F 'Unmanaged.passUnretained' -- 'Packages/**/Sources/**/*.swift' ':(exclude,glob)Packages/Shared/CmuxSafeConcurrency/**/CallbackRegistry*.swift')" = 0 "git grep Unmanaged.passUnretained"

row 7 "input-reachable trap sites in closure modules" "$(jqa trap-classify.json --argjson roots "$ROOTS_JSON" 'if (.hits | type) != "array" then "missing" else
  ([.hits[] | select(.class == "input" and (.path as $p | any($roots[]; . as $r | $p | startswith($r + "/")))) | .hits] | add // 0) end')" = 0 "crash_ratchet.py --report trap_api,index_subscript,int_conversion --all-modules --classify"
row 7 "uniqueKeysWithValues" "$(lines -F uniqueKeysWithValues -- 'Packages/**/Sources/**')" = 0 "git grep uniqueKeysWithValues"
row 7 "objc_raises in the modules of tasks 167-170" "$(jqa objc-raises.json --argjson mods "$OBJC_MODULES" 'if (.objc_raises.modules | type) != "object" then "missing" else
  ([.objc_raises.modules | to_entries[] | select(.key as $k | $mods | index($k)) | .value] | add // 0) end')" = 0 "crash_ratchet.py --report objc_raises"
row 7 "raising FileHandle reads" "$(lines -E 'availableData|seekToEndOfFile\(\)|readData\(ofLength' -- 'Packages/**/Sources/**')" = 0 "git grep availableData|seekToEndOfFile()|readData(ofLength"
row 7 "Invariant.check / dumpWillBeCheck sites without allowlist entry" "$(exit_of invariant-allowlist)" = 0 "exit of invariant-allowlist: crash_ratchet.py --report invariant_check"

panic_crates=missing
compgen -G "$ART/rust-panic*.json" >/dev/null && panic_crates="$(jq -s '[.[] | to_entries[] | select(.value.deny | not)] | length' "$ART"/rust-panic*.json 2>/dev/null || echo missing)"
row 8 "Rust crates with a deny-lint hit (Linux + macOS)" "$panic_crates" = 0 "rust_panic_ratchet.py --clippy-json linux=.. --clippy-json macos=.. --report json"
for class in unwrap expect panic_macro exit; do
  row 8 "crash-safety-baseline rust $class" "$(jq --arg c "$class" '[(.rust[$c] // {})[]] | add // 0' $S/crash-safety-baseline.json)" = 0 "jq .rust.$class scripts/cmux-next/crash-safety-baseline.json"
done

row 9 "FFI exports without ffi_boundary or ffi-nopanic" "$(scan ffi-unguarded)" = 0 "stability_final_scan.py ffi-unguarded --list (each extern \"C\" fn body)"
pin="$(grep -oE 'cmux-app-ffi-[0-9a-f]{40}' Packages/macOS/CmuxNext/Package.swift | head -n 1)"; pin="${pin#cmux-app-ffi-}"
INPUTS=()
while IFS= read -r line; do INPUTS+=("$line"); done < <($S/check-app-ffi-pin.sh --list-inputs 2>/dev/null)
pin_missing=0
for task in 152 156; do
  own=0
  if [[ ${#INPUTS[@]} -gt 0 ]]; then
    # The task's own commits (subject "p10-stability-NNN: ..." or "p10-stability-NNN (fixer): ...") that change a pin input.
    while IFS= read -r commit; do
      own=$((own + 1))
      [[ -n $pin ]] && git merge-base --is-ancestor "$commit" "$pin" 2>/dev/null || pin_missing=$((pin_missing + 1))
    done < <(git log --no-merges --format='%H %s' HEAD -- "${INPUTS[@]}" | awk -v t="p10-stability-$task" '$2 == t || $2 == t ":" { print $1 }')
  fi
  [[ $own -gt 0 ]] || pin_missing=$((pin_missing + 1))
done
row 9 "task 152/156 commits missing from the CCmuxAppFFI pin" "$pin_missing" = 0 "git merge-base --is-ancestor <each own commit on a check-app-ffi-pin.sh --list-inputs path> <pin sha>"
exit_row 9 check-app-ffi-pin "scripts/cmux-next/check-app-ffi-pin.sh"

row 10 "async-blocking-scan findings" "$(jqa async-blocking-scan.json 'if type == "array" then length else ([.findings[]?] | length) end')" = 0 "cargo run --manifest-path cmux-tui/tools/async-blocking-scan/Cargo.toml -- --root cmux-tui/crates --json"
exit_row 10 lab-clippy-disallowed "CLIPPY_CONF_DIR=cmux-tui/lab/clippy cargo clippy (0 disallowed_methods outside cmux-blocking)"
row 10 "supervise_* calls without a policy and a ShutdownBehavior" "$(scan supervise-unnamed)" = 0 "stability_final_scan.py supervise-unnamed --list"

undocumented=missing
if compgen -G "$ART/clippy-report-*.jsonl" >/dev/null; then
  undocumented=0
  for run in "$ART"/clippy-report-*.jsonl; do
    # Proof the lint was on (its flags) and the run finished; else the count proves nothing.
    if ! grep -q 'undocumented_unsafe_blocks' "${run%.jsonl}.flags" 2>/dev/null \
      || ! jq -e -s 'any(.[]; .reason == "build-finished" and .success == true)' "$run" >/dev/null 2>&1; then
      undocumented=unproven
      break
    fi
    undocumented=$((undocumented + $(jq -s '[.[] | select(.reason == "compiler-message" and .message.code.code == "clippy::undocumented_unsafe_blocks")] | length' "$run")))
  done
fi
row 11 "undocumented_unsafe_blocks" "$undocumented" = 0 "clippy --message-format=json -- \$(rust_panic_ratchet.py --report-flags)"
row 11 "unsafe-free cmux-tui crates without forbid(unsafe_code)" "$(scan forbid-unsafe-missing)" = 0 "stability_final_scan.py forbid-unsafe-missing --list"
row 11 "unsafe impl Send/Sync without SAFETY and a test reference" "$(scan unsafe-impl-undocumented)" = 0 "stability_final_scan.py unsafe-impl-undocumented --list"

cef=missing
warnings="$ART/cef-shim-warnings.txt"
if [[ -f $warnings ]]; then
  if [[ $(count "$warnings" .) == 1 ]] && grep -qxE '[[:space:]]*[0-9]+[[:space:]]*' "$warnings"; then
    cef="$(tr -d '[:space:]' <"$warnings")"
  else
    cef="$(count "$warnings" '-Wunsafe-buffer-usage')"
  fi
fi
row 12 "-Wunsafe-buffer-usage warnings in the CEF shim" "$cef" = 0 "build-cef-shim.sh warning file"
flags=0
for f in -Werror=unsafe-buffer-usage _LIBCPP_HARDENING_MODE_FAST -ftrivial-auto-var-init=pattern -fstack-protector-strong; do grep -qF -e "$f" $S/build-cef-shim.sh || flags=$((flags + 1)); done
row 12 "hardening flags missing from build-cef-shim.sh" "$flags" = 0 "grep <4 flags> scripts/cmux-next/build-cef-shim.sh"

swift_san="$(jqa sanitizer-swift/summary.json 'if .complete != true or ((.incomplete // []) | length) > 0 then "incomplete"
  elif (["thread", "address", "undefined", "coop-strict"] - (.modes // []) | length) > 0 then "modes" else "complete" end')"
if [[ $swift_san == complete ]]; then
  swift_san=missing
  [[ -f $ART/sanitizer-swift/findings.jsonl ]] && swift_san="$(count "$ART/sanitizer-swift/findings.jsonl" .)"
fi
row 13 "Swift sanitizer findings (thread,address,undefined,coop-strict)" "$swift_san" = 0 "sanitizer-sweep.sh --sanitize thread,address,undefined,coop-strict --ref SHA"
row 13 "reasoned TSan suppressions" "$(grep -cv -E '^[[:space:]]*(#|$)' $S/tsan-suppressions.txt)" "<=" 10 "grep -cv comments scripts/cmux-next/tsan-suppressions.txt"
row 14 "Rust sanitizer and Miri: runs missing or red, findings" "$(scan rust-sanitize "$ART/sanitizer-rust")" = 0 "cmux-tui/scripts/sanitize.sh --sanitizer address,thread,leak,miri (Linux and macOS)"
exit_row 14 loom-holder-ring "loom test of the holder ring"

row 15 "Rust fuzz targets" "$(scan fuzz-targets)" ">=" 40 "stability_final_scan.py fuzz-targets --list ([[bin]] of the fuzz Cargo.toml files)"
row 15 "Swift suites on CmuxFuzzSupport" "$(scan fuzz-suites)" ">=" 25 "stability_final_scan.py fuzz-suites --list"
exit_row 15 swift-libfuzzer "the >= 6 coverage-guided Swift libFuzzer targets, 30 min each, 0 crashes"
fuzz_list="$($S/rust-fuzz.sh --list 2>/dev/null | jq -R . | jq -s -c 'map(select(length > 0))')"
fuzz_unrun=missing
[[ $fuzz_list != "[]" && -n $fuzz_list ]] && fuzz_unrun="$(jqe rust-fuzz/summary.jsonl -s --argjson want "$fuzz_list" '$want - map(.target) | length')"
row 15 "rust-fuzz.sh --list targets with no run" "$fuzz_unrun" = 0 "rust-fuzz.sh --all --seconds 1800 summary.jsonl"
row 15 "Rust fuzz runs with a finding or not under the malloc limit" "$(jqe rust-fuzz/summary.jsonl -s '[.[] | select(.verdict != "clean" or .malloc_limit_mb != 256)] | length')" = 0 "rust-fuzz.sh (-rss_limit_mb=2048 -malloc_limit_mb=256 -timeout=2)"
row 15 "shortest Rust fuzz run (s)" "$(jqe rust-fuzz/summary.jsonl -s 'if length == 0 then "missing" else (map(.seconds) | min) end')" ">=" 1800 "rust-fuzz.sh summary.jsonl seconds"

exit_row 16 os-matrix-fuzz "os-matrix.sh --build JOB --os 14,15,26,27 --suite fuzz --minutes 60 (x 4 seeds)"
exit_row 16 os-matrix-chaos "os-matrix.sh --build JOB --os 14,15,26,27 --suite chaos"

exit_row 17 process-chaos-gpu-crash-loop "process-chaos-e2e.py --only gpu-crash-loop on the final tip (bare metal)"
for name in process-chaos-e2e child-crash-e2e crash-ends-app-gate state-corruption-e2e; do
  exit_row 17 "$name" "$name.py on the final tip (bare metal)"
done
chaos_pid=missing chaos_p99=missing gpu_loop=missing
if compgen -G "$ART/process-chaos/*.jsonl" >/dev/null; then
  chaos_rows="$(cat "$ART"/process-chaos/*.jsonl | jq -s -c '[.[] | select(.outcome != "skip")]' 2>/dev/null)"
  chaos_pid="$(jq '[.[] | select(.app_pid_kept != true)] | length' <<<"$chaos_rows" 2>/dev/null || echo missing)"
  chaos_p99="$(jq 'if length == 0 then "missing" else (map(.main_ping_ms.p99 // 1e9) | max) end' <<<"$chaos_rows" 2>/dev/null || echo missing)"
  gpu_loop="$(jq '[.[] | select(.fault == "gpu-crash-loop" and .outcome == "ok")] | length' <<<"$chaos_rows" 2>/dev/null || echo missing)"
fi
row 17 "chaos kills that changed the app pid" "$chaos_pid" = 0 "process-chaos-e2e.py --out: app_pid_kept"
row 17 "worst main-thread ping p99 during a kill (ms)" "$chaos_p99" "<=" 250 "process-chaos-e2e.py --out: main_ping_ms.p99"
row 17 "gpu-crash-loop kills that passed" "$gpu_loop" ">=" 1 "process-chaos-e2e.py --only gpu-crash-loop --out"

exit_row 18 hang-scope-tests "HangWatchScope tests: 0 kevent per scope, blocked-scope top frame"
exit_row 18 rust-watch-scope-tests "cmux-panic-log watch_scope tests: blocked-scope top frame"
exit_row 18 bench-idle-wakeups "bench-idle wakeups unchanged before/after task 031"

coverage="$(python3 -B $S/stability-lab.py coverage --since 72h --json 2>/dev/null)"
uncovered="$(jq -r '.summary.uncovered // "error"' <<<"$coverage" 2>/dev/null)"
percent="$(jq -r '.summary.percent // "?"' <<<"$coverage" 2>/dev/null)"
row 19 "landed commits in no tip that passed the fast lanes" "${uncovered:-error}" = 0 "stability-lab.py coverage --since 72h (${percent:-?} % covered)"
owned="$(jq -r '[.owners[].github_issue] | map(tostring) | join(",")' $S/stability-other-owners.json)"
row 19 "stability-sig issues > 24 h old with no fix in review" "$(scan stability-sig "$ART/stability-sig.json" "$ART/stability-sig-prs.json" "$owned")" = 0 "gh issue list -l stability-sig + gh pr list (#N in an open PR)"

row 20 "24 h soak, 10 agents, bare metal" "$(jqa soak/report.json 'if .ok != true then "failed" elif (.hours // 0) < 24 then "hours:\(.hours)"
  elif (.setup.agents // 0) < 10 then "agents:\(.setup.agents)" else "ok" end')" = ok "readiness-soak.py --hours 24 --agents 10"
row 20 "6 h ASan soak, Chromium off" "$(jqa soak-asan/report.json 'if .ok != true then "failed" elif (.hours // 0) < 6 then "hours:\(.hours)"
  elif .sanitizer.mode? != "asan" then "mode:\(.sanitizer.mode?)" else "ok" end')" = ok "readiness-soak.py --hours 6 --app-config asan"

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
