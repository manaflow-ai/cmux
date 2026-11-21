#!/usr/bin/env bash
# The fleet half of the visual expectation gate: renders the web surfaces of a pull request merged
# into its base (GitHub's refs/pull/N/merge), or of this checkout, and writes into $FAST_CHECKS_OUT:
#   captures/        the head's pictures in the gate's layout (capture-web.ts)
#   base/expectations, base/baselines   the base's rules and checked-in baselines (what the head is judged by)
#   head/expectations                   the head's rules (to list edits to them)
#   report/          gate.ts run with no PR body (every change unexplained), for a quick look
#   meta.json        {pr, merge, base, head}
# The lane half (review.sh) reads the PR body, judges, uploads the pictures and posts the comment;
# this run has no token, so it never reads or writes the PR.
#
#   cmux-ci test --setup webviews --timeout 2400 --artifact DIR -- \
#     bash scripts/gallery-matrix/expectations/fleet-capture.sh pr 43019
#   ... fleet-capture.sh here      # this checkout: the pictures to check in as baselines
set -euo pipefail

mode=${1:?usage: fleet-capture.sh pr N | here}
out=${FAST_CHECKS_OUT:?run under cmux-ci test}
repo=$(git rev-parse --show-toplevel)
gate="$repo/scripts/gallery-matrix/expectations"
work=$(mktemp -d)
mkdir -p "$out/base" "$out/head"

if [ "$mode" = pr ]; then
  pr=${2:?pr number}
  case "$pr" in *[!0-9]*) echo "pr must be a number" >&2; exit 2 ;; esac
  git -C "$repo" fetch -q --depth=2 https://github.com/manaflow-ai/cmux.git "+refs/pull/$pr/merge:refs/visual-gate/merge"
  merge=$(git -C "$repo" rev-parse refs/visual-gate/merge)
  base=$(git -C "$repo" rev-parse refs/visual-gate/merge^1)
  head=$(git -C "$repo" rev-parse refs/visual-gate/merge^2)
  tree="$work/tree"
  git -C "$repo" worktree add -q --detach "$tree" "$merge"
  base_tree="$work/base-tree"
  git -C "$repo" worktree add -q --detach "$base_tree" "$base"
  # The base's rules and baselines: a PR is judged by what it merges into, never by its own edits.
  # A base from before the gate landed has none; this checkout's rules stand in.
  if [ -d "$base_tree/design/visual-expectations" ]; then
    cp -R "$base_tree/design/visual-expectations" "$out/base/expectations"
  else
    cp -R "$repo/design/visual-expectations" "$out/base/expectations"
  fi
else
  pr=
  merge=$(git -C "$repo" rev-parse HEAD)
  base=$merge
  head=$merge
  tree=$repo
  cp -R "$repo/design/visual-expectations" "$out/base/expectations"
fi
cp -R "$tree/design/visual-expectations" "$out/head/expectations" 2>/dev/null || cp -R "$out/base/expectations" "$out/head/expectations"
mkdir -p "$out/base/expectations/baselines"
mv "$out/base/expectations/baselines" "$out/base/baselines"
rm -rf "$out/head/expectations/baselines"
printf '{"pr": %s, "merge": "%s", "base": "%s", "head": "%s"}\n' "${pr:-null}" "$merge" "$base" "$head" > "$out/meta.json"

# The gallery as the merged tree builds it, and the gate's browser from this checkout, side by side.
( cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null && CMUX_GALLERY_OUT_DIR="$work/gallery" bun run gallery:build >"$work/build.log" 2>&1 ) &
build=$!
( cd "$repo/scripts/gallery-matrix" && bun install --frozen-lockfile >/dev/null && "$repo/scripts/ci/ensure-system-chrome.sh" >"$work/chrome.log" 2>&1 ) &
browser=$!
# The base rendered live on this same machine: what the gate compares with when the checked-in
# baselines are missing or were drawn by another renderer (review.sh picks).
if [ -n "$pr" ]; then
  ( cd "$base_tree/webviews" && bun install --frozen-lockfile >/dev/null && CMUX_GALLERY_OUT_DIR="$work/gallery-base" bun run gallery:build >"$work/build-base.log" 2>&1 ) &
  base_build=$!
fi
wait "$build" || { tail -40 "$work/build.log"; exit 1; }
wait "$browser" || { tail -40 "$work/chrome.log"; exit 1; }
shell=$(grep -E '^CMUX_CHROME_HEADLESS_SHELL=' "$work/chrome.log" | tail -1 | cut -d= -f2- || true)
export CMUX_GALLERY_IN_VM=1 CMUX_CHROME_HEADLESS_SHELL="${shell:-${CMUX_CHROME_HEADLESS_SHELL:-}}"

# Every surface the head declares, so a PR adding one shows it as new.
bun "$gate/capture-web.ts" --expectations "$out/head/expectations" --gallery-dir "$work/gallery" --out "$out/captures"
if [ -n "$pr" ]; then
  wait "$base_build" || { tail -40 "$work/build-base.log"; exit 1; }
  bun "$gate/capture-web.ts" --expectations "$out/base/expectations" --gallery-dir "$work/gallery-base" --out "$out/base-render"
fi

bun "$gate/gate.ts" --expectations "$out/base/expectations" --head-expectations "$out/head/expectations" \
  --baselines "$out/base/baselines" --captures "$out/captures" --out "$out/report" \
  ${pr:+--pr "$pr"} --head-sha "$head" --base-sha "$base" || true
if [ -n "$pr" ]; then
  git -C "$repo" worktree remove --force "$tree"
  git -C "$repo" worktree remove --force "$base_tree"
fi
