#!/usr/bin/env bash
# .github/actions/runner-cargo-home/runner-cargo-home.sh (run by the
# runner-cargo-home and setup-cmux-tui-rust actions) gives each runner
# instance on a shared-HOME host its own CARGO_HOME. With one ~/.cargo, a
# sibling job's rust-cache post step deleted ~/.cargo/registry/src under a
# running cargo build (runs 42477732646 and 42478799348, 2026-11-08).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/actions/runner-cargo-home/runner-cargo-home.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Runs the script as runner $2 under HOME $1, with an optional NAME=value $3;
# prints the output dir.
run_as() {
  local home="$1" runner="$2" extra="${3:-UNUSED_EXTRA=1}" out
  out="$(mktemp -d "$TMP/out.XXXXXX")"
  mkdir -p "$home/$runner/_work/_temp"
  : > "$out/env"; : > "$out/path"
  env -u CARGO_HOME HOME="$home" RUNNER_OS=macOS RUNNER_TEMP="$home/$runner/_work/_temp" \
    GITHUB_ENV="$out/env" GITHUB_PATH="$out/path" "$extra" bash "$SCRIPT" > "$out/log"
  echo "$out"
}

# A shared host: three runner instances under one HOME, with a host cargo config.
shared="$TMP/shared"
for r in actions-runner-glaeda actions-runner-glaeda-1 actions-runner-glaeda-2; do
  mkdir -p "$shared/$r"; echo '{}' > "$shared/$r/.runner"
done
mkdir -p "$shared/.cargo/registry/src"
echo '[net]' > "$shared/.cargo/config.toml"

a="$(run_as "$shared" actions-runner-glaeda-1)"
b="$(run_as "$shared" actions-runner-glaeda-2)"
home_a="$shared/actions-runner-glaeda-1/_work/.cargo-home"
home_b="$shared/actions-runner-glaeda-2/_work/.cargo-home"
[ "$(cat "$a/env")" = "CARGO_HOME=$home_a" ] || fail "runner 1 env: $(cat "$a/env")"
[ "$(cat "$b/env")" = "CARGO_HOME=$home_b" ] || fail "runner 2 env: $(cat "$b/env")"
[ "$(cat "$a/path")" = "$home_a/bin" ] || fail "runner 1 path: $(cat "$a/path")"
[ -d "$home_a/bin" ] && [ -d "$home_b/bin" ] || fail "the cargo homes were not made"
[ "$(readlink "$home_a/config.toml")" = "$shared/.cargo/config.toml" ] || fail "the host cargo config is not linked"
[ ! -e "$home_a/registry" ] || fail "the host registry leaked into the runner's cargo home"

# What rust-cache's cleanup does to one runner's registry leaves the other's.
mkdir -p "$home_a/registry/src/index/walkdir-2.5.0" "$home_b/registry/src/index/walkdir-2.5.0"
rm -rf "$home_b/registry/src/index/walkdir-2.5.0"
[ -d "$home_a/registry/src/index/walkdir-2.5.0" ] || fail "runner 2's cleanup reached runner 1's crate sources"

# A second run keeps the existing link and home.
again="$(run_as "$shared" actions-runner-glaeda-1)"
[ "$(cat "$again/env")" = "CARGO_HOME=$home_a" ] || fail "a rerun changed CARGO_HOME"

# A host with one runner instance (an ephemeral VM) keeps its CARGO_HOME.
single="$TMP/single"
mkdir -p "$single/runner"; echo '{}' > "$single/runner/.runner"
s="$(run_as "$single" runner)"
[ ! -s "$s/env" ] && [ ! -s "$s/path" ] || fail "a single-runner host got a CARGO_HOME"
[ ! -e "$single/runner/_work/.cargo-home" ] || fail "a single-runner host got a cargo home dir"

# A runner with no .runner of its own (a container job) keeps its CARGO_HOME.
c="$(run_as "$shared" container)"
[ ! -s "$c/env" ] || fail "a job outside the runner dirs got a CARGO_HOME"

# A job that sets CARGO_HOME itself keeps it.
k="$(run_as "$shared" actions-runner-glaeda "CARGO_HOME=$TMP/job-cargo")"
[ ! -s "$k/env" ] || fail "a job's own CARGO_HOME was replaced"

# dtolnay/rust-toolchain's CARGO_HOME=$HOME/.cargo is the shared home: replaced.
d="$(run_as "$shared" actions-runner-glaeda "CARGO_HOME=$shared/.cargo")"
[ "$(cat "$d/env")" = "CARGO_HOME=$shared/actions-runner-glaeda/_work/.cargo-home" ] \
  || fail "the shared \$HOME/.cargo from dtolnay/rust-toolchain was kept: $(cat "$d/env")"
d="$(run_as "$shared" actions-runner-glaeda "CARGO_HOME=$shared/.cargo/")"
[ -s "$d/env" ] || fail "the shared \$HOME/.cargo/ (trailing slash) was kept"

# Windows runners keep theirs.
w="$(run_as "$shared" actions-runner-glaeda RUNNER_OS=Windows)"
[ ! -s "$w/env" ] || fail "a Windows runner got a CARGO_HOME"

echo "PASS: setup-cmux-tui-rust gives each shared-HOME runner its own CARGO_HOME"
