#!/usr/bin/env bash
# scripts/ci/keep-job-zig-first.sh: a zig link left in a runner's ~/.cargo/bin
# must not shadow the zig the job installed once install-rust-ci.sh (or the
# setup-cmux-tui-rust action) puts ~/.cargo/bin on GITHUB_PATH. Stub zigs print
# their version; stub rustup and cargo answer what install-rust-ci.sh asks.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

stub_zig() { mkdir -p "$1"; printf '#!/bin/sh\necho %s\n' "$2" > "$1/zig"; chmod +x "$1/zig"; }

# What the next step runs: every GITHUB_PATH line in front of the job's PATH,
# the last one written first (the runner's prepend order), then BASH_ENV.
next_step_zig() {
  local path="$1" line
  while IFS= read -r line; do path="$line:$path"; done < "$GITHUB_PATH"
  env -i HOME="$HOME" PATH="$path" BASH_ENV="${BASH_ENV:-}" bash -c 'zig version'
}

export HOME="$TMP/home"
mkdir -p "$HOME/.cargo/bin" "$TMP/bin"
# The leftover: a 0.16.0 zig beside rustup's proxies (two runner Macs had one).
stub_zig "$HOME/.cargo/bin" 0.16.0
# The zig setup-zig put on the job's PATH for ghostty-next.
stub_zig "$TMP/tool/zig/0.17.0" 0.17.0
cat > "$TMP/bin/rustup" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "target list") echo aarch64-apple-darwin; echo x86_64-apple-darwin ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho "cargo 1.95.0 (stub)"\n' > "$TMP/bin/cargo"
printf '#!/bin/sh\necho "rustc 1.95.0 (stub)"\n' > "$TMP/bin/rustc"
chmod +x "$TMP/bin/rustup" "$TMP/bin/cargo" "$TMP/bin/rustc"
JOB_PATH="$TMP/tool/zig/0.17.0:$TMP/bin:/usr/bin:/bin"

# 1. install-rust-ci.sh keeps the job's zig first, in GITHUB_PATH and BASH_ENV.
export RUNNER_TEMP="$TMP/runner-temp" GITHUB_PATH="$TMP/github_path" BASH_ENV="$TMP/bash_env"
mkdir -p "$RUNNER_TEMP"; : > "$GITHUB_PATH"; : > "$BASH_ENV"
(cd "$TMP" && PATH="$JOB_PATH" bash "$ROOT/scripts/install-rust-ci.sh" >/dev/null 2>&1) \
  || fail "install-rust-ci.sh exited non-zero"
got=$(next_step_zig "$JOB_PATH")
[[ "$got" == 0.17.0 ]] || fail "after install-rust-ci.sh the next step runs zig $got, want the job's 0.17.0"

# 2. A second call in the same job keeps pointing at the job's zig (no self link).
: > "$GITHUB_PATH"
dir=$(PATH="$RUNNER_TEMP/cmux-job-zig:$JOB_PATH" bash "$ROOT/scripts/ci/keep-job-zig-first.sh" \
  "$RUNNER_TEMP/cmux-job-zig/zig" 2>/dev/null)
[[ "$(readlink "$dir/zig")" == "$TMP/tool/zig/0.17.0/zig" ]] \
  || fail "second call links $(readlink "$dir/zig"), want the job's zig"

# 3. No zig before the step: nothing is written and nothing printed.
: > "$GITHUB_PATH"
out=$(bash "$ROOT/scripts/ci/keep-job-zig-first.sh" "" 2>&1)
[[ -z "$out" && ! -s "$GITHUB_PATH" ]] || fail "an empty ZIG changed GITHUB_PATH or printed: $out"

# 4. Windows is left alone (a copied zig.exe loses its lib directory).
out=$(RUNNER_OS=Windows bash "$ROOT/scripts/ci/keep-job-zig-first.sh" "$TMP/tool/zig/0.17.0/zig" 2>&1)
[[ -z "$out" && ! -s "$GITHUB_PATH" ]] || fail "Windows changed GITHUB_PATH or printed: $out"

# 5. The setup-cmux-tui-rust action records zig before it changes PATH and calls
#    the helper after it writes ~/.cargo/bin to GITHUB_PATH.
action="$ROOT/.github/actions/setup-cmux-tui-rust/action.yml"
z=$(grep -n 'job_zig="$(command -v zig' "$action" | cut -d: -f1)
p=$(grep -n 'export PATH="$HOME/.cargo/bin:$PATH"' "$action" | head -1 | cut -d: -f1)
g=$(grep -n 'echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"' "$action" | cut -d: -f1)
k=$(grep -n 'bash "$KEEP_JOB_ZIG_FIRST" "$job_zig"' "$action" | cut -d: -f1)
[[ -n "$z" && -n "$p" && -n "$g" && -n "$k" && "$z" -lt "$p" && "$g" -lt "$k" ]] \
  || fail "setup-cmux-tui-rust does not keep the job's zig first (lines z=$z p=$p g=$g k=$k)"

echo "keep-job-zig-first: ok"
