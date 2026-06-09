#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/open-diff-viewer-stress-samples.sh [sample|all] [--cli PATH] [--root PATH]

Clone large public repositories, check out sample refs, then open the diff
through the normal local git codepath:

  cmux diff --branch --base <base-ref>

Samples:
  bun-rust      Bun Zig-to-Rust rewrite, oven-sh/bun pull 30412
  node-v8       Node.js V8 update, nodejs/node pull 62526
  node-v8-14-1  Node.js V8 14.1 update, nodejs/node pull 59805
  linux-v6      Linux v6.0 to v6.7 compare
  all           Open every sample

Environment:
  CMUX_WORKSPACE_ID and CMUX_SURFACE_ID choose the target workspace/surface.
  CMUX_DIFF_STRESS_ROOT overrides the clone cache root. Each sample family gets
  its own parent directory so the normal cmux repo switcher does not treat
  unrelated stress repos as sibling production repos.
EOF
}

SAMPLE="bun-rust"
CLI="cmux"
ROOT="${CMUX_DIFF_STRESS_ROOT:-/tmp/cmux-diff-viewer-stress}"

if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      ;;
    *)
      SAMPLE="$1"
      shift
      ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --cli)
      CLI="${2:?missing --cli path}"
      shift 2
      ;;
    --root)
      ROOT="${2:?missing --root path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

sample_repo() {
  case "$1" in
    bun-rust) echo "https://github.com/oven-sh/bun.git" ;;
    node-v8|node-v8-14-1) echo "https://github.com/nodejs/node.git" ;;
    linux-v6) echo "https://github.com/torvalds/linux.git" ;;
    *) return 1 ;;
  esac
}

sample_dir() {
  case "$1" in
    bun-rust) echo "bun-rust/bun" ;;
    node-v8|node-v8-14-1) echo "node/node" ;;
    linux-v6) echo "linux-v6/linux" ;;
    *) return 1 ;;
  esac
}

sample_fetch_args() {
  case "$1" in
    bun-rust) echo "0d9b296af33f2b851fcbf4df3e9ec89751734ba4 pull/30412/head:refs/remotes/cmux-stress/bun-rust" ;;
    node-v8) echo "4d8834fbef690bf71dc9eb6bdd9edfb0783b3c5d pull/62526/head:refs/remotes/cmux-stress/node-v8" ;;
    node-v8-14-1) echo "0817b40c1b2938cff3c30f026d0ad4b255beb11d pull/59805/head:refs/remotes/cmux-stress/node-v8-14-1" ;;
    linux-v6) echo "refs/tags/v6.0:refs/tags/v6.0 refs/tags/v6.7:refs/tags/v6.7" ;;
    *) return 1 ;;
  esac
}

sample_head_ref() {
  case "$1" in
    bun-rust) echo "refs/remotes/cmux-stress/bun-rust" ;;
    node-v8) echo "refs/remotes/cmux-stress/node-v8" ;;
    node-v8-14-1) echo "refs/remotes/cmux-stress/node-v8-14-1" ;;
    linux-v6) echo "refs/tags/v6.7" ;;
    *) return 1 ;;
  esac
}

sample_base_ref() {
  case "$1" in
    bun-rust) echo "0d9b296af33f2b851fcbf4df3e9ec89751734ba4" ;;
    node-v8) echo "4d8834fbef690bf71dc9eb6bdd9edfb0783b3c5d" ;;
    node-v8-14-1) echo "0817b40c1b2938cff3c30f026d0ad4b255beb11d" ;;
    linux-v6) echo "refs/tags/v6.0" ;;
    *) return 1 ;;
  esac
}

sample_branch() {
  case "$1" in
    bun-rust) echo "cmux-stress-bun-rust" ;;
    node-v8) echo "cmux-stress-node-v8" ;;
    node-v8-14-1) echo "cmux-stress-node-v8-14-1" ;;
    linux-v6) echo "cmux-stress-linux-v6" ;;
    *) return 1 ;;
  esac
}

sample_title() {
  case "$1" in
    bun-rust) echo "Stress: Bun Zig-to-Rust rewrite" ;;
    node-v8) echo "Stress: Node.js V8 update" ;;
    node-v8-14-1) echo "Stress: Node.js V8 14.1 update" ;;
    linux-v6) echo "Stress: Linux v6.0 to v6.7 compare" ;;
    *) return 1 ;;
  esac
}

ensure_repo() {
  local name="$1"
  local repo_url repo_dir
  repo_url="$(sample_repo "$name")"
  repo_dir="$ROOT/$(sample_dir "$name")"
  mkdir -p "$(dirname "$repo_dir")"
  if [ ! -d "$repo_dir/.git" ]; then
    git clone --filter=blob:none --no-checkout "$repo_url" "$repo_dir"
  fi
  printf '%s\n' "$repo_dir"
}

open_sample() {
  local name="$1"
  local repo_dir fetch_args head_ref branch base_ref title
  repo_dir="$(ensure_repo "$name")"
  fetch_args="$(sample_fetch_args "$name")"
  head_ref="$(sample_head_ref "$name")"
  branch="$(sample_branch "$name")"
  base_ref="$(sample_base_ref "$name")"
  title="$(sample_title "$name")"

  echo "fetching $name in $repo_dir"
  # shellcheck disable=SC2086
  git -C "$repo_dir" fetch --filter=blob:none origin $fetch_args
  git -C "$repo_dir" checkout -B "$branch" "$head_ref"

  local args=(diff --branch --base "$base_ref" --title "$title" --layout split --no-focus)
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    args+=(--workspace "$CMUX_WORKSPACE_ID")
  fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then
    args+=(--surface "$CMUX_SURFACE_ID")
  fi

  echo "opening $name through local git: cd $repo_dir && $CLI ${args[*]}"
  (cd "$repo_dir" && "$CLI" "${args[@]}")
}

case "$SAMPLE" in
  all)
    open_sample bun-rust
    open_sample node-v8
    open_sample node-v8-14-1
    open_sample linux-v6
    ;;
  bun-rust|node-v8|node-v8-14-1|linux-v6)
    open_sample "$SAMPLE"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
