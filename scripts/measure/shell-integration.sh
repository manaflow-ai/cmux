#!/usr/bin/env bash
# Shell integration costs nothing per prompt (perf-lead row 20), measured where a PID-gap count is
# valid: alone on an idle Mac. The fork guard (cmux-tui-core shell_integration::fork_count_tests) and
# the bench (scripts/cmux-next/shell-integration-bench.py) count forks as the gap in the system PID
# counter, so any other process on the host counts as a shell fork. An isolated step shares its
# worker with other steps and gives no verdict ("unstable baseline"); this exclusive step does.
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/shell-integration.sh --ref SHA \
#     --artifact artifacts/shell-integration/report.tgz [--arg=bash52=0] [--arg=app=1]
# Steps (each runs after the prerequisites; a failed one does not stop the next):
#   host     host, macOS, arch, load, the shells' versions, the ghostty-next pin.
#   guard    the fork-count and prompt-redraw tests through scripts/ci/cmux-tui-rust-check.sh, with
#            CMUX_FORK_COUNT_REQUIRE=zsh,fish,bash5.3 set here (the controller does not pass that
#            variable to a step), so a missing shell fails instead of skipping. Nothing else of the
#            step forks during the run: nextest runs the fork counts alone, and the check's PTY
#            sampler starts no process (pty_watch_start).
#   bench    the bench on this checkout, layouts app, daemon, daemon-bare; zsh, fish and Homebrew
#            bash 5.3 required.
#   bash52   (default on) the bench on bash 5.2.37 built from the sha256-pinned GNU tarball: the
#            bash 4.4-5.2 budget (Ghostty's PS0 command substitution, 2 forks per command).
#   app      (app=1) builds a tagged app at this checkout (reload.sh) and runs the bench on its
#            bundle (--app), the files the app really ships.
# Exit: 0 every step passed, 1 a check failed, 2 no verdict and no failure (Homebrew
# bash 5.3 or fish not installed, the bash tarball unavailable). AWS Macs have neither Homebrew bash
# nor fish: run on a cmux mini.
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

bash53=/opt/homebrew/bin/bash
# The fork guard's own fish candidates (fork_count_fish_forks_nothing), so a fish it cannot find
# gives no verdict here instead of a red guard.
fish=/opt/homebrew/bin/fish
for candidate in /opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish; do
  if [[ -x "$candidate" ]]; then fish="$candidate"; break; fi
done
bash_version() { "$1" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null; }
echo "SHELL-INTEGRATION-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) \
ghostty_next=$(git -C ghostty-next rev-parse HEAD) macos=$(sw_vers -productVersion) arch=$(uname -m) \
bash=$(bash_version "$bash53" || echo none) zsh=$(zsh --version 2>/dev/null | awk '{print $2}') \
fish=$("$fish" --version 2>/dev/null | awk '{print $3}') load=\"$(uptime | sed 's/.*load averages*: //')\""
prereq=0
[[ -x "$bash53" ]] && [[ "$(bash_version "$bash53" | awk -F. '{print ($1 > 5 || ($1 == 5 && $2 >= 3))}')" == 1 ]] \
  || { echo "shell-integration: $bash53 is missing or older than 5.3" >&2; prereq=2; }
[[ -x "$fish" ]] || { echo "shell-integration: fish is not installed" >&2; prereq=2; }
[[ -x /bin/zsh ]] || { echo "shell-integration: /bin/zsh is missing" >&2; prereq=2; }
record prerequisites "$prereq"
# A host without the shells gives no verdict: stop before a run that could only skip them.
(( prereq == 0 )) || exit 2

# guard: the test processes inherit the variable through nextest. No rerun: a fork count that
# fails once on an idle host is a fork, not a flake.
CMUX_FORK_COUNT_REQUIRE=zsh,fish,bash5.3 CMUX_RUST_CHECK_RERUN_MAX=0 \
  ./scripts/ci/cmux-tui-rust-check.sh test shell_integration:: > "$out/guard.log" 2>&1
rc=$?
grep -E "PASS|FAIL|SKIP|skipped|unstable|forked|budget" "$out/guard.log" | tail -n 60
record guard "$rc"

bench() {  # bench NAME ARGS...: one bench run, its log and json under $out
  local name="$1"; shift
  python3 -I scripts/cmux-next/shell-integration-bench.py --json "$out/$name.json" "$@" > "$out/$name.log" 2>&1
  local rc=$?
  cat "$out/$name.log"
  record "$name" "$rc"
}
bench bench --bash "$bash53" --shells zsh,bash,fish --require zsh,bash,fish

if [[ "$bash52" == 1 ]]; then
  version=5.2.37
  sha=9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
  tarball="$work/bash-$version.tar.gz"
  got=""
  for mirror in https://mirrors.kernel.org/gnu/bash https://ftp.gnu.org/gnu/bash; do
    curl --proto '=https' -fsSL --retry 3 -o "$tarball" "$mirror/bash-$version.tar.gz" || continue
    got="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    [[ "$got" == "$sha" ]] && break
  done
  if [[ "$got" != "$sha" ]]; then
    echo "shell-integration: bash-$version tarball unavailable or sha256 '$got' is not $sha" >&2
    record bash52 2
  elif ! (cd "$work" && tar xzf "$tarball" && cd "bash-$version" \
      && ./configure -q --prefix="$work/bash52" --without-bash-malloc && make -s -j"$(sysctl -n hw.ncpu)" \
      && make -s install) > "$out/bash52-build.log" 2>&1; then
    tail -n 40 "$out/bash52-build.log"
    record bash52 2
  else
    bench bash52 --bash "$work/bash52/bin/bash" --shells bash --require bash
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
    bench app --app "$app_path" --bash "$bash53" --shells zsh,bash,fish --require zsh,bash,fish
  fi
fi

tar -czf "$work/report.tgz" -C "$out" . && mv "$work/report.tgz" "$out/report.tgz"
# A failed check is red even when another step gave no verdict.
if (( failed )); then result=1; elif (( no_verdict )); then result=2; else result=0; fi
echo "SHELL-INTEGRATION-RESULT exit=$result"
exit "$result"
