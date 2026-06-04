#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/open-diff-viewer-stress-samples.sh [sample|all] [--cli PATH]

Open Pierre/DiffsHub-style large public diffs in the current cmux workspace.

Samples:
  bun-rust      Bun Zig-to-Rust rewrite, oven-sh/bun pull 30412
  node-v8       Node.js V8 update, nodejs/node pull 62526
  node-v8-14-1  Node.js V8 14.1 update, nodejs/node pull 59805
  linux-v6      Linux v6.0 to v6.7 compare
  all           Open every sample

Environment:
  CMUX_WORKSPACE_ID and CMUX_SURFACE_ID choose the target workspace/surface.
  CMUX_DIFF_VIEWER_STREAM_REMOTE defaults to 1 so the viewer streams remote patches.
EOF
}

SAMPLE="${1:-bun-rust}"
CLI="cmux"
if [ "${2:-}" = "--cli" ]; then
  CLI="${3:?missing --cli path}"
fi

case "$SAMPLE" in
  -h|--help)
    usage
    exit 0
    ;;
esac

sample_url() {
  case "$1" in
    bun-rust) echo "https://diffshub.com/oven-sh/bun/pull/30412" ;;
    node-v8) echo "https://diffshub.com/nodejs/node/pull/62526" ;;
    node-v8-14-1) echo "https://diffshub.com/nodejs/node/pull/59805" ;;
    linux-v6) echo "https://diffshub.com/torvalds/linux/compare/v6.0...v6.7" ;;
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

open_sample() {
  local name="$1"
  local url title
  url="$(sample_url "$name")"
  title="$(sample_title "$name")"
  echo "opening $name: $url"
  local args=(diff "$url" --title "$title" --layout split --no-focus)
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    args+=(--workspace "$CMUX_WORKSPACE_ID")
  fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then
    args+=(--surface "$CMUX_SURFACE_ID")
  fi
  CMUX_DIFF_VIEWER_STREAM_REMOTE="${CMUX_DIFF_VIEWER_STREAM_REMOTE:-1}" "$CLI" "${args[@]}"
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
