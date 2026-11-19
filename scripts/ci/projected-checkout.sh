#!/usr/bin/env bash
# A CI checkout from the runner host's own git mirror through `cmux-projection git-mount` (RFD 0007, #47100),
# instead of writing every file of the commit. For a persistent Linux runner with FUSE: the mount is up in about
# half a second, writes nothing per file, and keeps the commit's mtimes and `target/` across jobs at the same path,
# so cargo finds its last build fresh.
#
#   projected-checkout.sh mount SHA PATH     mount SHA at PATH; prints mode=projected or mode=checkout (and why)
#   projected-checkout.sh unmount PATH       end a mount at PATH, also one whose server died (lazy unmount)
#   projected-checkout.sh seed SHA PATH      after a normal checkout of SHA at PATH: make the mirror and build the
#                                            binary for the next job (bounded, never fails the job)
#
# Every failure of `mount` is a fallback, never a red job: the workflow then runs actions/checkout as before.
# A step that reads this script takes it from the mirror (git show SHA:scripts/ci/projected-checkout.sh), because
# the checkout it would come from is what it makes.
#
# env: CMUX_CI_GIT_MIRROR (default ~/.cache/cmux-ci/git/cmux.git), CMUX_CI_PROJECTION_HOME
#      (default ~/.cache/cmux-ci/projection), CMUX_CI_REMOTE (default https://github.com/manaflow-ai/cmux.git),
#      GITHUB_OUTPUT (mode/reason/seconds are appended when set).
set -uo pipefail

MIRROR=${CMUX_CI_GIT_MIRROR:-$HOME/.cache/cmux-ci/git/cmux.git}
HOME_DIR=${CMUX_CI_PROJECTION_HOME:-$HOME/.cache/cmux-ci/projection}
REMOTE=${CMUX_CI_REMOTE:-https://github.com/manaflow-ai/cmux.git}
CRATE=cmux-tui/crates/cmux-projection

out() {
  echo "$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi
}

now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'; }

# The binary that serves SHA: keyed by the crate's tree and the workspace lock at SHA, so a commit whose
# cmux-projection changed waits for its own build (made by `seed`) instead of running an older one.
binary_key() {
  local sha=$1 crate lock
  crate=$(git --git-dir "$MIRROR" rev-parse --verify -q "$sha:$CRATE") || return 1
  lock=$(git --git-dir "$MIRROR" rev-parse --verify -q "$sha:cmux-tui/Cargo.lock") || return 1
  printf '%s-%s' "${crate:0:16}" "${lock:0:16}"
}

is_mounted() { # PATH: a FUSE mount there, alive or dead
  awk -v p="$1" '$2 == p && $3 ~ /^fuse/ { found = 1 } END { exit !found }' /proc/self/mounts
}

cmd_unmount() {
  local at=$1
  if is_mounted "$at"; then
    fusermount3 -u "$at" 2>/dev/null || fusermount3 -u -z "$at" 2>/dev/null || true
  fi
  if is_mounted "$at"; then
    echo "projected-checkout: $at is still mounted" >&2
    return 1
  fi
}

fallback() {
  out "mode=checkout"
  out "reason=$1"
  echo "::notice title=projected checkout::normal checkout: $1"
  exit 0
}

cmd_mount() {
  local sha=$1 at=$2 start key bin ready log pid
  start=$(now)
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fallback "not a full commit id: $sha"
  [ "$(uname -s)" = Linux ] || fallback "not Linux"
  [ -c /dev/fuse ] && [ -r /dev/fuse ] && [ -w /dev/fuse ] || fallback "no usable /dev/fuse"
  command -v fusermount3 >/dev/null || fallback "no fusermount3"
  [ -d "$MIRROR" ] || fallback "no mirror at $MIRROR (seed makes it)"
  cmd_unmount "$at" || fallback "a stale mount at $at would not unmount"
  # The mirror is shared by the host's runner slots: one fetch at a time.
  exec 9>"$MIRROR.lock"
  flock -w 120 9 || fallback "mirror lock busy for 120 s"
  if ! git --git-dir "$MIRROR" cat-file -e "$sha^{commit}" 2>/dev/null; then
    timeout 180 git --git-dir "$MIRROR" fetch -q --no-tags --depth 1 origin "$sha" \
      || fallback "mirror fetch of $sha failed"
  fi
  flock -u 9
  key=$(binary_key "$sha") || fallback "$sha has no $CRATE"
  bin=$HOME_DIR/bin/$key/cmux-projection
  [ -x "$bin" ] || fallback "no cmux-projection built for $key yet (seed builds it)"
  mkdir -p "$at" "$HOME_DIR/run"
  ready=$HOME_DIR/run/$(printf '%s' "$at" | sha1sum | cut -c1-16).ready
  log=$RUNNER_TEMP/projected-checkout.log
  [ -n "${RUNNER_TEMP:-}" ] || log=$HOME_DIR/run/last.log
  rm -f "$ready"
  # The server outlives this step: its own session, out of the step's process group. The runner's end-of-job
  # cleanup or the always() unmount step ends it; a server that died leaves a dead mount that the next job's
  # `mount` (or `unmount`) takes off before its own checkout.
  setsid "$bin" git-mount --git-dir "$MIRROR" --commit "$sha" --at "$at" --fresh --ready-file "$ready" \
    </dev/null >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do
    [ -s "$ready" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -s "$ready" ]; then
    kill "$pid" 2>/dev/null || true
    cmd_unmount "$at" || true
    cat "$log" >&2 || true
    fallback "git-mount did not come up within 60 s"
  fi
  if [ "$(git -C "$at" rev-parse HEAD 2>/dev/null)" != "$sha" ] || [ ! -f "$at/cmux-tui/Cargo.toml" ]; then
    kill "$pid" 2>/dev/null || true
    cmd_unmount "$at" || true
    fallback "the mount at $at is not $sha"
  fi
  out "mode=projected"
  out "pid=$pid"
  out "seconds=$(since "$start")"
  echo "::notice title=projected checkout::$sha mounted at $at in $(since "$start") s ($(cat "$ready"))"
}

cmd_seed() {
  local sha=$1 at=$2 key bin target
  # 1. The mirror: a bare repo the host keeps, fetched one commit deep per job.
  if [ ! -d "$MIRROR" ]; then
    mkdir -p "$(dirname "$MIRROR")"
    git init -q --bare "$MIRROR.tmp.$$" && git --git-dir "$MIRROR.tmp.$$" remote add origin "$REMOTE" \
      && mv -T "$MIRROR.tmp.$$" "$MIRROR" || { rm -rf "$MIRROR.tmp.$$"; echo "seed: no mirror" >&2; return 0; }
  fi
  exec 9>"$MIRROR.lock"
  flock -w 120 9 || { echo "seed: mirror lock busy" >&2; return 0; }
  git --git-dir "$MIRROR" cat-file -e "$sha^{commit}" 2>/dev/null \
    || timeout 300 git --git-dir "$MIRROR" fetch -q --no-tags --depth 1 origin "$sha" \
    || { echo "seed: mirror fetch failed" >&2; return 0; }
  flock -u 9
  # 2. The binary, built from the checkout this job already made (one build per crate or lock change).
  key=$(binary_key "$sha") || { echo "seed: $sha has no $CRATE" >&2; return 0; }
  bin=$HOME_DIR/bin/$key/cmux-projection
  [ -x "$bin" ] && return 0
  command -v cargo >/dev/null || { echo "seed: no cargo" >&2; return 0; }
  target=$HOME_DIR/target
  mkdir -p "$HOME_DIR/bin/$key"
  exec 8>"$HOME_DIR/build.lock"
  flock -w 600 8 || { echo "seed: build lock busy" >&2; return 0; }
  [ -x "$bin" ] && return 0
  if (cd "$at/cmux-tui" && CARGO_TARGET_DIR=$target timeout 900 cargo build -q --release --locked -p cmux-projection) \
    && "$target/release/cmux-projection" 2>&1 | grep -q git-mount; then
    cp "$target/release/cmux-projection" "$bin.tmp" && mv "$bin.tmp" "$bin"
    echo "seed: built $bin"
  else
    echo "seed: cmux-projection at $sha did not build or has no git-mount" >&2
  fi
}

case "${1:-}" in
  mount) cmd_mount "$2" "$3" ;;
  unmount) cmd_unmount "$2" ;;
  seed) cmd_seed "$2" "$3" ;;
  *) echo "usage: projected-checkout.sh mount|seed SHA PATH | unmount PATH" >&2; exit 2 ;;
esac
