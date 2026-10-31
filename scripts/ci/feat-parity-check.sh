#!/usr/bin/env bash
# feat-cmux-next checks that had no fleet mode, as a cmux-ci step, so a merge train or an agent
# can run them on a pushed commit (the perf/chrome-parity train-parity table, 2026-10-29):
#   cmux-ci run --class light --script scripts/ci/feat-parity-check.sh --ref SHA --key KEY \
#     --arg MODE [--arg ROOT]
# Each mode runs the workflow's own commands, from the checkout root:
#   rust-workspace ROOT  rust-workspaces.yml's job for ROOT, a `run = true` root of
#                        .github/rust-workspaces.toml: its own toolchain pin (a root with no
#                        rust-toolchain.toml gets cmux-tui's, as setup-cmux-tui-rust makes it the
#                        job's default) and clippy, the
#                        ghostty-next checkout when the root uses ghostty-vt-sys, then
#                        `rust-workspaces.py run ROOT` (clippy --all-targets -D warnings and
#                        cargo test). `rust-workspaces.py plan --base BASE` names the roots a
#                        change reaches. Needs python 3.11 or later (tomllib).
#   sdk-rust             cmux-tui-sdks.yml `packages` (rust): fmt --check, tests, doc tests and
#                        clippy -D warnings of cmux-sdk and cmux-sidebar, cmux-sdk without default
#                        features, rustdoc -D warnings, and the two `cargo package` checks.
#   sdk-msrv             cmux-tui-sdks.yml `rust-msrv`: the public Rust SDK crates and examples
#                        on Rust 1.88 (installed with rustup into the step's RUSTUP_HOME).
#   cef-shim-cpp         cmux-next-shim-cpp.yml: every scripts/cmux-next/test-*-cpp.sh, then the
#                        Chromium Host's C++ tests where the commit has them
#                        (scripts/cmux-next/tests/chromium-host-dispatch.test.sh and
#                        remote-shim-abi.test.sh, on perf/chrome-parity).
#   swift-portable PKG   swift-packages-linux.yml for one package its matrix lists:
#                        `swift build --build-tests`, then `swift test --skip-build --parallel`
#                        when it has Tests, with CMUX_SWIFTPM_TARGET_LINUX=1. Linux only (the
#                        job runs in swift:6.2-noble, with libsqlite3-dev): elsewhere it exits 78.
#   web                  ci-web.yml's web/ checks: bun install --frozen-lockfile, the managed
#                        relay catalog check, typecheck, lint:complexity and the unit tests
#                        (all four shards in one run), with the bun ci-web.yml pins.
#   notices              cmux-next-guards.yml rust-notices-tree's "Generate the Rust notices from
#                        this tree (as the nightly does)": generate-third-party-notices.sh
#                        --tui-source tree --write-cargo-trees with CMUX_NOTICES_ALLOW_CARGO=1 (cargo
#                        writes the exact cargo trees). cmux-tui's pinned cargo runs every
#                        `cargo tree --locked` (a Linux fleet runner's rustup has no default
#                        toolchain for a tree with no pin). Its crate cache and trees are in the
#                        step's .build. The caller decides whether the change reaches a notice input
#                        (the job's "Changed notice inputs" step).
# Every step of a mode runs, even after a red one; the summary lists each, and the step exits
# with the first red step's code. Nothing is committed or pushed. Cargo runs only as a fleet
# step: outside one (CMUX_CI_STEP_KEY) the script refuses.
set -euo pipefail
usage() {
  echo "usage: feat-parity-check.sh rust-workspace ROOT | swift-portable PKG | sdk-rust | sdk-msrv | cef-shim-cpp | web | notices" >&2
  exit 2
}
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
feat-parity-check.sh runs cargo, compilers and tests and runs only as a fleet step:
  cmux-ci run --class light --script scripts/ci/feat-parity-check.sh --ref SHA --key KEY --arg MODE
MSG
  exit 2
fi
mode="${1:-}"
workspace="${2:-}"
case "$mode" in
  rust-workspace | swift-portable)
    [[ $# -eq 2 && "$workspace" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$workspace/" != *"/../"* && "/$workspace/" != *"/./"* ]] || usage
    ;;
  sdk-rust | sdk-msrv | cef-shim-cpp | web | notices) [[ $# -eq 1 ]] || usage ;;
  *) usage ;;
esac
umask 022
root="$(pwd -P)"
# The web job's bun (ci-web.yml `Setup Bun`); web/run-tests.sh needs 1.3.14 or later.
web_bun_pin=1.4.4
msrv=1.88.0

first_rc=0
step_rows=()
step() { # NAME CMD...: runs CMD, records pass or fail and seconds
  local name="$1" t0 rc=0
  shift
  echo "=== step $name: $*"
  t0=$SECONDS
  "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    step_rows+=("$name"$'\t'"pass"$'\t'"$((SECONDS - t0))")
  else
    step_rows+=("$name"$'\t'"FAIL (exit $rc)"$'\t'"$((SECONDS - t0))")
    [[ "$first_rc" -ne 0 ]] || first_rc=$rc
  fi
  return 0
}
finish() {
  local row a b c
  echo
  echo "=== feat-parity-check summary (mode $mode${workspace:+, root $workspace})"
  printf '%-36s %-16s %s\n' step result seconds
  for row in ${step_rows[@]+"${step_rows[@]}"}; do
    IFS=$'\t' read -r a b c <<<"$row"
    printf '%-36s %-16s %s\n' "$a" "$b" "$c"
  done
  if [[ "$first_rc" -ne 0 ]]; then
    echo "feat-parity-check: RED (first red step exit $first_rc)"
  else
    echo "feat-parity-check: green"
  fi
  exit "$first_rc"
}
# The pinned toolchain's own cargo first on PATH (as cmux-tui-rust-check.sh does), from DIR.
use_pinned_cargo() { # DIR
  local cargo_bin
  (cd "$1" && rustup component add clippy rustfmt) || { echo "error: rustup component add clippy rustfmt failed in $1" >&2; return 3; }
  cargo_bin="$(cd "$1" && rustup which cargo)" || { echo "error: rustup which cargo failed in $1" >&2; return 3; }
  PATH="$(dirname "$cargo_bin"):$PATH"
  export PATH
  echo "cargo: $cargo_bin"
}
# Puts the cargo rustup selects in ROOT first on PATH, for the rest of the step.
use_root_cargo() { # ROOT
  local cargo_bin
  cargo_bin="$(cd "$root/$1" && rustup which cargo)" || { echo "error: rustup which cargo failed in $1" >&2; return 3; }
  PATH="$(dirname "$cargo_bin"):$PATH"
  export PATH
  echo "cargo: $cargo_bin"
}
# As cmux-tui-rust-check.sh: a synced copy without the gitlink uses the files present;
# otherwise the commit's gitlink, with init-submodule.sh's retries.
ghostty_next() {
  if [[ -z "$(git -C "$root" submodule status ghostty-next 2>/dev/null || true)" && -f "$root/ghostty-next/build.zig" ]]; then
    echo "ghostty-next: no gitlink in this tree (a synced copy); using the files present"
    return 0
  fi
  (cd "$root" && bash scripts/ci/init-submodule.sh ghostty-next)
}
# The root's toolchain: nothing when a rust-toolchain(.toml) applies from ROOT up, else
# cmux-tui's channel (setup-cmux-tui-rust makes it the job's default).
root_toolchain() { # ROOT
  local dir="$root/$1"
  while :; do
    if [[ -f "$dir/rust-toolchain.toml" || -f "$dir/rust-toolchain" ]]; then
      return 0
    fi
    [[ "$dir" != "$root" ]] || break
    dir="$(dirname "$dir")"
  done
  python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["toolchain"]["channel"])' "$root/cmux-tui/rust-toolchain.toml"
}

if [[ "$mode" == rust-workspace ]]; then
  python3 -c 'import sys, tomllib' 2>/dev/null || { echo "error: rust-workspace needs python 3.11 or later (tomllib) as python3" >&2; exit 3; }
  # Every `run = true` root, with what its job needs (no --base plans every one).
  plan="$(python3 .github/scripts/rust-workspaces.py plan)" || { echo "error: rust-workspaces.py plan failed" >&2; exit 3; }
  needs="$(python3 -I -c '
import json, sys
jobs = {j["root"]: j for j in json.loads(sys.argv[1])}
j = jobs.get(sys.argv[2])
if j is None:
    raise SystemExit(1)
print(("1" if j.get("ghostty") else "0") + "\t" + (j.get("apt") or ""))
' "$plan" "$workspace")" || { echo "error: $workspace is not a run = true root of .github/rust-workspaces.toml" >&2; exit 2; }
  IFS=$'\t' read -r uses_ghostty apt <<<"$needs"
  # Its own target dir per root, inside the checkout: a warm slot keeps .build between steps.
  CARGO_TARGET_DIR="$root/.build/rust-workspace-target/${workspace//\//__}"
  export CARGO_TARGET_DIR
  if [[ -n "$apt" ]]; then
    if [[ "$(uname -s)" == Linux ]] && command -v apt-get >/dev/null && sudo -n true 2>/dev/null; then
      # shellcheck disable=SC2086 # the entry's apt list is space-separated package names
      step "apt $apt" sh -c 'sudo -n apt-get update && sudo -n apt-get install -y "$@"' _ $apt
    else
      step "apt $apt" sh -c 'echo "error: this host cannot install the apt packages $1" >&2; exit 3' _ "$apt"
    fi
  fi
  if [[ "$uses_ghostty" == 1 ]]; then
    export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC=""
    step "ghostty-next" ghostty_next
  fi
  fallback="$(root_toolchain "$workspace")" || { echo "error: cannot read cmux-tui/rust-toolchain.toml" >&2; exit 3; }
  if [[ -n "$fallback" ]]; then
    echo "toolchain: $workspace has no rust-toolchain.toml; using cmux-tui's $fallback"
    export RUSTUP_TOOLCHAIN="$fallback"
    step "toolchain" bash -c 'rustup toolchain install "$2" --profile minimal --component clippy --component rustfmt && cd "$1" && cargo --version' _ "$workspace" "$fallback"
  else
    step "toolchain" bash -c 'cd "$1" && rustup toolchain install && rustup component add clippy && cargo --version' _ "$workspace"
  fi
  # The toolchain's own cargo first on PATH (its bin dir holds cargo-clippy and cargo-fmt): the
  # cargo on a fleet step's PATH is not always the rustup proxy, and then `cargo clippy` finds no
  # cargo-clippy (2026-10-29, step dbb2c454 on cmux8s). rustup picks the root's pin, or
  # RUSTUP_TOOLCHAIN for an unpinned root, from the root's folder.
  step "toolchain cargo" use_root_cargo "$workspace"
  step "clippy and tests" python3 .github/scripts/rust-workspaces.py run "$workspace"
  finish
fi

if [[ "$mode" == sdk-rust ]]; then
  export CARGO_TARGET_DIR="$root/.build/cmux-tui-rust-target"
  step "pinned cargo" use_pinned_cargo "$root/cmux-tui"
  cd "$root/cmux-tui"
  step "fmt" cargo fmt -p cmux-sdk -p cmux-sidebar -- --check
  step "test" cargo test -p cmux-sdk -p cmux-sidebar --all-targets --locked
  step "doc tests" cargo test -p cmux-sdk -p cmux-sidebar --doc --locked
  step "clippy" cargo clippy -p cmux-sdk -p cmux-sidebar --all-targets --locked -- -D warnings
  # Embedders such as Chromium build without sha2 (socket-path-hash).
  step "test no-default-features" cargo test -p cmux-sdk --all-targets --locked --no-default-features
  step "clippy no-default-features" cargo clippy -p cmux-sdk --all-targets --locked --no-default-features -- -D warnings
  step "rustdoc" env RUSTDOCFLAGS="-D warnings" cargo doc -p cmux-sdk -p cmux-sidebar --locked --no-deps
  step "package cmux-sdk" cargo package -p cmux-sdk --locked
  step "package cmux-sidebar (list)" cargo package -p cmux-sidebar --locked --list
  finish
fi

if [[ "$mode" == sdk-msrv ]]; then
  export CARGO_TARGET_DIR="$root/.build/sdk-msrv-target"
  step "rust $msrv" rustup toolchain install "$msrv" --profile minimal --component clippy --component rustfmt
  b="$root/cmux-tui/bindings"
  step "fmt rust" rustup run "$msrv" cargo fmt --manifest-path "$b/rust/Cargo.toml" -- --check
  step "test rust" rustup run "$msrv" cargo test --manifest-path "$b/rust/Cargo.toml" --locked
  step "test rust-sidebar" rustup run "$msrv" cargo test --manifest-path "$b/rust-sidebar/Cargo.toml" --locked
  step "test rust-agent-screen-detection" rustup run "$msrv" cargo test --manifest-path "$b/examples/rust-agent-screen-detection/Cargo.toml" --locked
  step "clippy rust-agent-dashboard" rustup run "$msrv" cargo clippy --manifest-path "$b/examples/rust-agent-dashboard/Cargo.toml" --locked --all-targets -- -D warnings
  step "clippy rust-sidebar-monitor" rustup run "$msrv" cargo clippy --manifest-path "$b/examples/rust-sidebar-monitor/Cargo.toml" --locked --all-targets -- -D warnings
  finish
fi

if [[ "$mode" == cef-shim-cpp ]]; then
  shopt -s nullglob
  tests=("$root"/scripts/cmux-next/test-*-cpp.sh)
  shopt -u nullglob
  [[ "${#tests[@]}" -gt 0 ]] || { echo "error: no scripts/cmux-next/test-*-cpp.sh at this commit" >&2; exit 2; }
  for t in "${tests[@]}"; do
    step "$(basename "$t" .sh)" "$t"
  done
  # The Chromium Host's dispatcher and remote shim ABI (C++ and the generated wire cases, no
  # AppKit), where this commit has them.
  for t in chromium-host-dispatch remote-shim-abi; do
    f="$root/scripts/cmux-next/tests/$t.test.sh"
    if [[ -f "$f" ]]; then
      step "$t.test" bash "$f"
    else
      echo "cef-shim-cpp: no scripts/cmux-next/tests/$t.test.sh at this commit"
    fi
  done
  finish
fi

if [[ "$mode" == notices ]]; then
  # The crate cache stays in .build (a warm slot keeps it between steps); the trees are written fresh.
  notices_dir="$root/.build/notices"
  rm -rf "$notices_dir/cargo-trees"
  mkdir -p "$notices_dir"
  step "pinned cargo" use_pinned_cargo "$root/cmux-tui"
  step "notices from the tree" env CMUX_NOTICES_ALLOW_CARGO=1 CMUX_NOTICES_CACHE="$notices_dir/cache" \
    ./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree \
    --cargo-trees "$notices_dir/cargo-trees" --write-cargo-trees
  finish
fi

if [[ "$mode" == swift-portable ]]; then
  pkg="$workspace"
  # The packages of swift-packages-linux.yml's matrix (`packages: >-` blocks).
  python3 -I - "$root/.github/workflows/swift-packages-linux.yml" "$pkg" <<'PY' || { echo "error: $pkg is not a package of swift-packages-linux.yml's matrix" >&2; exit 2; }
import re, sys
listed, block = set(), None
for line in open(sys.argv[1], encoding="utf-8"):
    indent = len(line) - len(line.lstrip())
    if re.match(r"\s*packages:\s*>-\s*$", line):
        block = indent
        continue
    if block is not None:
        if line.strip() and indent > block and re.fullmatch(r"Packages/[A-Za-z0-9._/-]+", line.strip()):
            listed.add(line.strip())
            continue
        block = None
raise SystemExit(0 if sys.argv[2] in listed else 1)
PY
  if [[ "$(uname -s)" != Linux ]]; then
    echo "error: swift-portable checks Linux portability and runs only on Linux, not $(uname -s)" >&2
    exit 78
  fi
  export CMUX_SWIFTPM_TARGET_LINUX=1
  step "swift build $pkg" swift build --package-path "$pkg" --build-tests
  if [[ "$first_rc" -eq 0 && -d "$pkg/Tests" ]]; then
    step "swift test $pkg" swift test --package-path "$pkg" --skip-build --parallel
  fi
  finish
fi

# web: the pinned bun, installed into the step's own .build when the host has another.
ensure_web_bun() {
  local dir="$root/.build/tools/bun-$web_bun_pin"
  if [[ "$(bun --version 2>/dev/null || true)" != "$web_bun_pin" ]]; then
    if [[ ! -x "$dir/bin/bun" ]]; then
      echo "installing bun $web_bun_pin into $dir"
      mkdir -p "$dir"
      curl -fsSL https://bun.sh/install | BUN_INSTALL="$dir" bash -s "bun-v$web_bun_pin" >/dev/null || return 3
    fi
    PATH="$dir/bin:$PATH"
    export PATH
  fi
  [[ "$(bun --version)" == "$web_bun_pin" ]] || { echo "error: bun is $(bun --version), not $web_bun_pin" >&2; return 3; }
  echo "bun: $(command -v bun) ($(bun --version))"
}
step "bun $web_bun_pin" ensure_web_bun
cd "$root/web"
step "bun install" bun install --frozen-lockfile
step "relay catalog" bun tools/generate-managed-iroh-relay-catalog.ts --check
# ci-web.yml retries the native TypeScript compiler once when it aborts; real type errors stay red.
web_typecheck() {
  local log rc=0
  log="$(mktemp)"
  bun run typecheck 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
  if [[ "$rc" -ne 0 ]] && grep -Fq 'Aborted (core dumped)' "$log"; then
    echo "native tsgo aborted during web typecheck; retrying once"
    rc=0
    bun run typecheck || rc=$?
  fi
  rm -f "$log"
  return "$rc"
}
step "typecheck" web_typecheck
step "lint:complexity" bun run lint:complexity
step "unit tests" ./scripts/run-tests.sh
finish
