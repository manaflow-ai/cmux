#!/usr/bin/env bash
# Repro for the Nightly walk's library/use-dir red (cmuxterm-hq customize_library_walk.py): the walk builds
# `cmux customize use dir:` from a sparse checkout (synthetic-probes.yml cmux-library: 9 folders), with a fresh
# HOME. This runs build-web-bundles.sh the same way on a Mac, sparse then full, so each reports on its own.
# Usage: scripts/cmux-next/customize-dir-sparse-repro.sh OUT_DIR
set -uo pipefail
src=$(git rev-parse --show-toplevel)
out=${1:?OUT_DIR}
mkdir -p "$out"
sparse=$(mktemp -d)/cmux-library
home=$(mktemp -d)
git clone -q --no-checkout --filter=blob:none "file://$src" "$sparse"
git -C "$sparse" sparse-checkout set --cone scripts webviews config schemas web/data Resources/markdown-viewer \
  Packages/macOS/CmuxNext/Sources release-notes/next cmux-tui/crates/acpmux/spec
git -C "$sparse" checkout -q "$(git -C "$src" rev-parse HEAD)"
step() {
  local name=$1 dir=$2
  local t0=$SECONDS
  (cd "$dir" && HOME="$home" scripts/cmux-next/build-web-bundles.sh --out-root "$out/$name-bundles") \
    >"$out/$name.log" 2>&1
  local code=$?
  echo "$name: exit $code in $((SECONDS - t0)) s"
  if [ "$code" != 0 ]; then
    grep -n -i -E "error|failed|✘|at pushAndCheck" "$out/$name.log" | grep -v -i warning | head -40
    echo "--- $name tail"
    tail -40 "$out/$name.log"
  fi
}
step sparse "$sparse"
step full "$src"
