#!/usr/bin/env bash
# The base's clippy target, for a cold clippy-changed slot (goal ci-min-per-pr-140).
#
#   clippy-base-seed.sh inputs              the 16-hex key of the toolchain and lockfiles (after the pinned cargo is on PATH)
#   clippy-base-seed.sh restore TARGET      seed an empty TARGET from the base's build; any failure is a miss, exit 0
#
# Leo, 2026-11-21: "whatever we need to cut, we cut. whatever we can reuse, we reuse."
#
# Why: 54% of fleet clippy-changed steps began on a just-created slot (median 486 s against 337 s on a reused one):
# an empty target, so every workspace crate and its build scripts (libghostty-vt's zig build, libtailscale's Go build)
# ran from nothing. Registry crates already come from sccache; the workspace does not. The seed is written only by
# cmux-tui-clippy-seed.yml on feat-cmux-next (the next-cache-writer environment), so a pull request only reads it:
#   cmux-tui-clippy-seed-deps-v1-<inputs>       dependencies only (cargo_target_strip.py)
#   cmux-tui-clippy-seed-ws-v1-<inputs>-<sha>   the workspace delta (cargo-target-delta.sh), with source mtimes
# restore puts the dependency entry in TARGET, the newest workspace delta on top, and gives every source whose bytes
# equal the base build's its recorded mtime back (scripts/ci/cargo-target-delta.sh apply), so Cargo rechecks only what
# this commit changed and its dependents. A changed file keeps a fresh mtime: correctness never rests on the seed.
# A reused slot (a target that already holds a build) is left alone. CMUX_CLIPPY_BASE_SEED=off turns it off.
# Test: scripts/ci/tests/clippy-base-seed.test.sh.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$repo/scripts/ci"
mode="${1:-}"

seed_inputs() {
  { git -C "$repo" ls-files -z -- 'cmux-tui/Cargo.lock' 'cmux-tui/**/Cargo.lock' 'cmux-tui/rust-toolchain.toml' '.cargo/config.toml' \
      | (cd "$repo" && xargs -0 sha256sum)
    rustc -Vv; cargo -V; } | sha256sum | cut -c1-16
}

# A target that already holds a build: any .fingerprint directory within four levels.
target_is_warm() {
  [[ -d "$1" ]] && [[ -n "$(find "$1" -maxdepth 4 -type d -name .fingerprint -print -quit 2>/dev/null)" ]]
}

restore() {
  local target="${1:-}" start=$SECONDS inputs overlay stamp
  [[ -n "$target" ]] || { echo "usage: $0 restore TARGET" >&2; return 2; }
  if [[ "${CMUX_CLIPPY_BASE_SEED:-}" == off ]]; then echo "clippy base seed: off"; return 0; fi
  if target_is_warm "$target"; then echo "clippy base seed: skipped, $target already holds a build (a reused slot)"; return 0; fi
  export CI_CACHE_R2_PUBLIC_URL="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache-next.cmux.com}"
  # The writer is a Linux X64 runner; a fleet step has no RUNNER_OS or RUNNER_ARCH.
  export CI_CACHE_R2_NAMESPACE="${CI_CACHE_R2_NAMESPACE:-Linux-X64}"
  inputs="$(seed_inputs)" || { echo "clippy base seed: miss (no key: $?)"; return 0; }
  overlay="$(mktemp -d "${TMPDIR:-/tmp}/clippy-seed-ws.XXXXXX")" || return 0
  stamp="$overlay.stamp"
  mkdir -p "$target"
  bash "$here/r2-cache.sh" restore "$target" "cmux-tui-clippy-seed-deps-v1-$inputs" "cmux-tui-clippy-seed-deps-v1-" \
    || echo "clippy base seed: dependency entry not restored"
  bash "$here/r2-cache.sh" restore "$overlay" "cmux-tui-clippy-seed-ws-v1-$inputs-" "cmux-tui-clippy-seed-ws-v1-$inputs-" "cmux-tui-clippy-seed-ws-v1-" \
    || echo "clippy base seed: workspace delta not restored"
  # x86_64-unknown-linux-gnu as the clippy job's warm target: libghostty-vt is built for baseline x86-64 (CMUX_GHOSTTY_VT_ZIG_CPU).
  bash "$here/cargo-target-delta.sh" apply "$target" "$overlay" "$stamp" x86_64-unknown-linux-gnu \
    || echo "clippy base seed: delta not applied"
  rm -f -- "$stamp" "$stamp.list"
  echo "clippy base seed: restore took $((SECONDS - start)) s into $target"
  return 0
}

case "$mode" in
  inputs) seed_inputs ;;
  restore) shift; restore "$@" ;;
  *) echo "usage: $0 inputs | restore TARGET" >&2; exit 2 ;;
esac
