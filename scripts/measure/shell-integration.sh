#!/usr/bin/env bash
# Shell integration costs nothing per prompt (perf-lead row 20): the fork guard
# (cmux-tui-core shell_integration::fork_count_tests) and the bench
# (scripts/cmux-next/shell-integration-bench.py) on one Mac with every shell they need, strict. On
# macOS both count the shell's own forks through the kernel (kqueue NOTE_FORK), so other processes
# on the host do not change the fork counts: the guard alone runs in any isolated step
# (cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --arg test
# --arg shell_integration:: --ref SHA). This step adds what that one cannot: the bench's
# first-prompt times (a timing, so alone on an idle worker), bash 5.2, and the strict shell list.
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/shell-integration.sh --ref SHA \
#     --artifact artifacts/shell-integration/report.tgz [--arg=bash52=0] [--arg=app=1]
# Steps (each runs after the prerequisites; a failed one does not stop the next):
# The shells are the pinned builds of scripts/ci/pinned-shell.sh (bash 5.3, bash 5.2.37, fish 4.9.3;
# sha256-pinned, made once per host and cached), the ones the fork guard runs, so any Mac gives a
# verdict, Homebrew or not.
#   host     host, macOS, arch, load, the shells' versions, the ghostty-next pin.
#   guard    the fork-count and prompt-redraw tests through scripts/ci/cmux-tui-rust-check.sh (on
#            macOS they run every shell; one they cannot get fails them).
#   bench    the bench on this checkout, layouts app, daemon, daemon-bare; zsh, fish and bash 5.3.
#   bash52   (default on) the bench on bash 5.2.37: the bash 4.4-5.2 budget (Ghostty's PS0 command
#            substitution: 1 fork of the shell per command). Partial on macOS: the kernel's count
#            misses forks inside the PS0 subshell and can merge two forks of the shell, so a pass
#            here is not the complete verdict (that is the PID gap on Linux, budget 2).
#   app      (app=1) builds a tagged app at this checkout (reload.sh) and runs the bench on its
#            bundle (--app), the files the app really ships.
# Exit: 0 every step passed, 1 a check failed, 2 no verdict and no failure (a pinned shell could not
# be downloaded or built).
set -uo pipefail
bash52=1
app=0
for arg in "$@"; do
  case "$arg" in
    bash52=*) bash52="${arg#bash52=}" ;;
    app=*) app="${arg#app=}" ;;
    *) echo "shell-integration.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 2
out="$root/artifacts/shell-integration"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/shell-integration.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git submodule update --init --depth 1 ghostty-next >/dev/null || { echo "shell-integration: ghostty-next checkout failed" >&2; exit 2; }

failed=0
no_verdict=0
record() {  # record NAME RC: prints the step verdict (rc 2: no verdict) and keeps it
  local verdict=PASS
  if (( $2 == 2 )); then verdict=NO-VERDICT; no_verdict=1; elif (( $2 != 0 )); then verdict=FAIL; failed=1; fi
  echo "SHELL-INTEGRATION-STEP $1 $verdict (rc $2)"
}

prereq=0
bash53="$(scripts/ci/pinned-shell.sh bash-5.3)" || prereq=2
fish="$(scripts/ci/pinned-shell.sh fish-4.9.3)" || prereq=2
bash_version() { "$1" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null; }
echo "SHELL-INTEGRATION-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) \
ghostty_next=$(git -C ghostty-next rev-parse HEAD) macos=$(sw_vers -productVersion) arch=$(uname -m) \
bash=$(bash_version "$bash53" || echo none) zsh=$(zsh --version 2>/dev/null | awk '{print $2}') \
fish=$("$fish" --version 2>/dev/null | awk '{print $3}') load=\"$(uptime | sed 's/.*load averages*: //')\""
[[ -x /bin/zsh ]] || { echo "shell-integration: /bin/zsh is missing" >&2; prereq=2; }
record prerequisites "$prereq"
# Without the shells there is no verdict: stop before a run that could only fail on them.
(( prereq == 0 )) || exit 2

# guard: no rerun: a fork count that fails once is a fork, not a flake.
CMUX_RUST_CHECK_RERUN_MAX=0 ./scripts/ci/cmux-tui-rust-check.sh test shell_integration:: \
  > "$out/guard.log" 2>&1
rc=$?
grep -E "PASS|FAIL|SKIP|FORK-COUNT|pinned-shell|skipped|unstable|forked|budget" "$out/guard.log" | tail -n 60
record guard "$rc"

bench() {  # bench NAME ARGS...: one bench run, its log and json under $out
  local name="$1"; shift
  python3 -I scripts/cmux-next/shell-integration-bench.py --json "$out/$name.json" "$@" > "$out/$name.log" 2>&1
  local rc=$?
  cat "$out/$name.log"
  record "$name" "$rc"
}
bench bench --bash "$bash53" --fish "$fish" --shells zsh,bash,fish --require zsh,bash,fish

if [[ "$bash52" == 1 ]]; then
  if bash52_path="$(scripts/ci/pinned-shell.sh bash-5.2.37)"; then
    bench bash52 --bash "$bash52_path" --shells bash --require bash
  else
    record bash52 2
  fi
fi

if [[ "$app" == 1 ]]; then
  tag="shellint"
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" > "$out/reload.log" 2>&1
  app_path="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
    record app 2
  else
    bench app --app "$app_path" --bash "$bash53" --fish "$fish" --shells zsh,bash,fish --require zsh,bash,fish
  fi
fi

tar -czf "$work/report.tgz" -C "$out" . && mv "$work/report.tgz" "$out/report.tgz"
# A failed check is red even when another step gave no verdict.
if (( failed )); then result=1; elif (( no_verdict )); then result=2; else result=0; fi
echo "SHELL-INTEGRATION-RESULT exit=$result"
exit "$result"
