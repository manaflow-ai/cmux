#!/usr/bin/env bash
# The cmux_next_ daemon tests' cargo build, warm from the last feat-cmux-next push: restored from the CI cache bucket
# (R2, public reads) by a pull request, saved only by a feat-cmux-next push.
#
#   scripts/ci/cmux-tui-test-target.sh restore   before the cargo build (any run; never writes the bucket)
#   scripts/ci/cmux-tui-test-target.sh save      after it (a feat-cmux-next push with the write credentials only)
#   scripts/ci/cmux-tui-test-target.sh floor     before any cache restore: make room for the build, or fail fast
#
# Why: ci/steps.toml's `cmux-next-daemon-tests` step compiled 626 crates cold on every routed pull request (27 min of a
# 29 min step, and a slow one hit the step's 65-minute bound), and `agent-pane-real-acpmux` built acpmux cold (6.4 min).
# The push-only job they came from (cmux-tui-artifacts.yml's `cmux_next_ daemon tests`) restored a Swatinem/rust-cache
# entry, but the GitHub store is full and evicts it (no `cmux-tui-linux` entry existed on 2026-11-24), and rust-cache keeps
# third-party crates only: the cmux-tui and cmux-tui-core lib test builds were 18 of its 22 compile minutes.
#
# So the whole target is kept, the workspace's own crates too, with the source manifest of the checkout it was built
# from (scripts/blacksmith-testbox-source-mtimes.py, as scripts/ci/pool-warm-target.sh does on a pool runner). After a
# restore every source whose bytes equal the recorded ones gets its recorded mtime back; a changed, added or unrecorded
# file keeps its fresh mtime, so cargo rebuilds what it feeds and every crate that depends on it. Restore runs inside the
# step, after the ghostty-next submodule is checked out, so its sources match too.
#
# Trust: only a feat-cmux-next push writes (r2-cache.sh needs the next-cache-writer credentials, which a pull request
# never holds). A pull request restores into its own checkout's cmux-tui/target, which the runner wipes after the job, and
# nothing it builds is ever read by a later job.
#
# Key: cmux-next-daemon-tests-cargo-v1-<build environment>-<4-hour window>. The environment is what cargo's fingerprints
# do not see (the pinned toolchain file, the host, its C compiler, the ghostty-next gitlink and the Zig pin) and the
# workspace path (fingerprints hold absolute paths). A save happens at most once a window (r2-cache.sh skips a key the
# bucket has), and a restore reads the newest save under the environment's prefix. r2_cache_prune.py keeps one day.
#
# Disk: a restore needs CMUX_TUI_TEST_TARGET_MIN_FREE_GIB (30) free, else it builds cold. A save drops incremental state
# first, and a target over CMUX_TUI_TEST_TARGET_MAX_GIB (14) keeps only third-party output (scripts/ci/cargo_target_strip.py).
# A restore that fails or is cut removes the half-unpacked target. A target that already holds a workspace build is kept
# as is; one with third-party output only (a rust-cache restore) gives way to a hit and comes back on a miss.
#
# Floor: the build needs CMUX_TUI_TEST_TARGET_BUILD_FLOOR_GIB (25) free on the target's disk and in TMPDIR. Under it,
# `floor` drops the target's incremental state, then the whole leftover target (a reused self-hosted workspace keeps
# it), and fails the step when the disk is still under CMUX_TUI_TEST_TARGET_HARD_FLOOR_GIB (12): the build would die
# 15 minutes later on "No space left on device" or an ld Bus error (run 45737327859, 2026-11-26), and a failed run is
# retried (cmux-tui-artifacts-retry.yml) on another runner instead.
set -euo pipefail

command="${1:-}"
if [[ "$command" != restore && "$command" != save && "$command" != floor ]] || (($# != 1)); then
  echo "usage: $0 restore|save|floor" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="$repo/cmux-tui/target"
manifest="$target/.cmux-testbox-source-mtimes.tsv"
min_free_gib="${CMUX_TUI_TEST_TARGET_MIN_FREE_GIB:-30}"
max_gib="${CMUX_TUI_TEST_TARGET_MAX_GIB:-14}"
build_floor_gib="${CMUX_TUI_TEST_TARGET_BUILD_FLOOR_GIB:-25}"
hard_floor_gib="${CMUX_TUI_TEST_TARGET_HARD_FLOOR_GIB:-12}"
export CI_CACHE_R2_PUBLIC_URL="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache-next.cmux.com}"
say() { echo "cmux-tui test target: $*"; }

# Only in GitHub Actions on this repository: a laptop or a lane keeps its own target.
if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_REPOSITORY:-}" != manaflow-ai/cmux ]]; then
  say "not a manaflow-ai/cmux Actions run; nothing to $command"
  exit 0
fi
# A runner that moves cargo's target elsewhere keeps its own (a fleet runner's shared target): never replace it.
if [[ -n "${CARGO_TARGET_DIR:-}" && "$(realpath -m "$CARGO_TARGET_DIR")" != "$target" ]]; then
  say "CARGO_TARGET_DIR is $CARGO_TARGET_DIR, not cmux-tui/target; nothing to $command"
  exit 0
fi

environment="$( {
  cat "$repo/cmux-tui/rust-toolchain.toml"
  uname -m
  grep -E '^(ID|VERSION_ID)=' /etc/os-release 2>/dev/null || true
  cc --version 2>/dev/null | head -n 1 || true
  clang --version 2>/dev/null | head -n 1 || true
  git -C "$repo" rev-parse HEAD:ghostty-next 2>/dev/null || echo no-ghostty-next
  sha256sum < "$repo/scripts/ci/zig-tarballs.sha256" 2>/dev/null || true
  echo "$repo"
} | sha256sum | cut -c1-16)"
prefix="cmux-next-daemon-tests-cargo-v1-$environment-"
window="$(date -u +%Y%m%d)h$(( 10#$(date -u +%H) / 4 * 4 ))"
key="$prefix$window"

free_gib() { df -Pk "$1" | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }

floor() {
  local here="$repo/cmux-tui" tmp="${TMPDIR:-/tmp}" free tmp_free
  free="$(free_gib "$here")"
  tmp_free="$(free_gib "$tmp")"
  if ((free >= build_floor_gib && tmp_free >= build_floor_gib)); then
    say "floor ok: ${free} GiB free here, ${tmp_free} GiB in $tmp (floor $build_floor_gib)"
    return 0
  fi
  say "under the $build_floor_gib GiB build floor: ${free} GiB free here, ${tmp_free} GiB in $tmp"
  if [[ -d "$target" ]]; then
    say "the leftover target is $(du -sxh "$target" 2>/dev/null | cut -f1); dropping its incremental state"
    find "$target" -mindepth 1 -maxdepth 3 -type d -name incremental -prune -exec rm -rf -- {} +
    free="$(free_gib "$here")"
    if ((free < build_floor_gib)); then
      say "still ${free} GiB free; removing the leftover target (cold build)"
      rm -rf -- "$target"
    fi
  fi
  free="$(free_gib "$here")"
  tmp_free="$(free_gib "$tmp")"
  df -Ph "$here" "$tmp" || true
  if ((free < hard_floor_gib || tmp_free < hard_floor_gib)); then
    echo "::error title=runner disk under the floor::${free} GiB free here, ${tmp_free} GiB in $tmp, under $hard_floor_gib after removing this workspace's cargo target; the build would die on No space left on device, so this runner is refused (a retry lands elsewhere)" >&2
    return 1
  fi
  say "now ${free} GiB free here, ${tmp_free} GiB in $tmp"
}

restore() {
  # A target holding a workspace build (a reused self-hosted workspace) is kept. One holding third-party output only
  # is a Swatinem/rust-cache restore (pr-pipeline.yml's web-browser job, this job's push side): rust-cache drops the
  # workspace's crates before saving, so keeping it skipped the R2 target and rebuilt all 91 of them (5m19s, job
  # 140315082442, 2026-11-27). Set it aside, take the R2 target, and put it back only on a miss.
  local aside=""
  if [[ -d "$target/debug" ]]; then
    if compgen -G "$target/debug/.fingerprint/acpmux-*" >/dev/null; then
      say "cmux-tui/target already holds a workspace build; kept, nothing restored"
      return 0
    fi
    aside="$target.third-party.$$"
    mv -- "$target" "$aside"
    say "cmux-tui/target holds third-party output only (a rust-cache restore); set aside, trying the full target"
  fi
  local outcome=miss
  restore_r2 && outcome=hit
  if [[ -n "$aside" ]]; then
    if [[ "$outcome" == hit ]]; then
      rm -rf -- "$aside"
    else
      rm -rf -- "$target"
      mv -- "$aside" "$target"
      say "kept the third-party output instead"
    fi
  fi
}

# Returns 0 when the bucket's target landed in cmux-tui/target, 1 otherwise (cmux-tui/target then holds nothing).
restore_r2() {
  mkdir -p "$target"
  local free tmp_free
  free="$(free_gib "$target")"
  tmp_free="$(free_gib "${TMPDIR:-/tmp}")"
  if ((free < min_free_gib || tmp_free < min_free_gib)); then
    say "miss (${free} GiB free here, ${tmp_free} GiB in ${TMPDIR:-/tmp}; under $min_free_gib); cold build"
    return 1
  fi
  local started=$SECONDS status=0
  # r2-cache.sh treats every error as a miss; the bound is ours, and a cut unpack leaves nothing behind.
  bash "$repo/scripts/ci/timeout.sh" 420 bash "$repo/scripts/ci/r2-cache.sh" restore "$target" "$key" "$prefix" || status=$?
  if ((status != 0)); then
    say "restore ended with status $status after $((SECONDS - started)) s; removing what it unpacked, cold build"
    rm -rf -- "$target"
    return 1
  fi
  if [[ ! -d "$target/debug" ]]; then
    say "miss ($prefix*): cold build"
    return 1
  fi
  if [[ -f "$manifest" && ! -L "$manifest" ]]; then
    python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" restore "$repo" "$manifest"
    say "hit in $((SECONDS - started)) s ($(du -sxh "$target" | cut -f1)); unchanged sources keep the build's mtimes"
  else
    say "hit in $((SECONDS - started)) s, third-party crates only (no source manifest); workspace crates rebuild"
  fi
  rm -f -- "$manifest"
  return 0
}

save() {
  if [[ "${GITHUB_EVENT_NAME:-}" != push || "${GITHUB_REF:-}" != refs/heads/feat-cmux-next ]]; then
    say "only a feat-cmux-next push saves; nothing saved"
    return 0
  fi
  if [[ ! -d "$target/debug" ]]; then
    say "no build in cmux-tui/target; nothing saved"
    return 0
  fi
  # The bucket keeps one save a window (r2-cache.sh skips a key it has): build nothing for a save that won't happen.
  local platform="${CI_CACHE_R2_NAMESPACE:-${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}}"
  if curl -sfI --max-time 20 "${CI_CACHE_R2_PUBLIC_URL%/}/v1/$platform/objects/$key.tar.zst" >/dev/null 2>&1; then
    say "the bucket already has $key; nothing saved"
    return 0
  fi
  # ci/steps.toml's agent-pane-real-acpmux restores this target and builds `-p acpmux --bin acpmux` alone. Cargo
  # resolves features over the packages one command names (dev-dependencies too, for `cargo test`), so the daemon
  # tests' build gives 159 third-party crates other features than acpmux's own build, other hashes, and every
  # agent-pane run rebuilt about 200 crates after a "hit" (5.8 to 9.1 min, no faster than a miss: 16 jobs,
  # 2026-11-26). Building acpmux here too puts its own feature set in the saved target.
  (cd "$repo/cmux-tui" && CARGO_INCREMENTAL=0 cargo build --locked -p acpmux --bin acpmux) \
    || say "cargo build -p acpmux ended with status $?; saving the test build as it is"
  find "$target" -mindepth 1 -maxdepth 3 -type d -name incremental -prune -exec rm -rf -- {} +
  rm -f -- "$manifest"
  local size_gib
  size_gib="$(du -sxk "$target" | awk '{ printf "%d", $1 / 1048576 }')"
  if ((size_gib > max_gib)); then
    say "the target is $size_gib GiB, over $max_gib: saving third-party output only"
    local crates
    mapfile -t crates < <(cargo metadata --no-deps --format-version 1 --manifest-path "$repo/cmux-tui/Cargo.toml" \
      | python3 -I -c 'import json,sys; m=json.load(sys.stdin); print("\n".join(sorted({p["name"] for p in m["packages"]} | {t["name"] for p in m["packages"] for t in p["targets"]})))')
    python3 -I "$repo/scripts/ci/cargo_target_strip.py" "$target" --workspace-crates "${crates[@]}"
  else
    python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" record "$repo" "$manifest"
  fi
  say "saving $(du -sxh "$target" | cut -f1) as $key"
  bash "$repo/scripts/ci/timeout.sh" 900 bash "$repo/scripts/ci/r2-cache.sh" save "$target" "$key" || say "save ended with status $?; nothing more to do"
}

"$command"
