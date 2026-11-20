#!/usr/bin/env bash
set -euo pipefail

# Compare the credential-free Cloud matrix behavior on two revisions. The
# checkout is the exact head under test, so the fleet runner can execute this
# file without relying on a caller's /tmp directory.
base=${BASE_SHA:-bee84039c3b5c527aeecbc4044fca6956649fd7f}
head=${HEAD_SHA:-$(git rev-parse HEAD)}
test "$(git rev-parse HEAD)" = "$head"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

for rev in "$base" "$head"; do
  tree="$tmp_dir/tree-$rev"
  mkdir -p "$tree"
  git archive "$rev" scripts/cmux-next | tar -x -C "$tree"
  out="$tmp_dir/out-$rev"
  mkdir -p "$out"

  set +e
  (
    cd "$tree"
    env -u ANTHROPIC_API_KEY -u CODEX_AUTH_JSON \
      bun scripts/cmux-next/cloud-claude-matrix.ts --auth api-key --models sonnet --out "$out"
  ) >"$tmp_dir/log-$rev" 2>&1
  code=$?
  set -e

  test -s "$out/matrix.md"
  printf '%s exit=%s\n' "$rev" "$code"
  sed -n '1,24p' "$out/matrix.md"
  if test "$rev" = "$base"; then
    test "$code" = 0
    grep -q '^PASS:' "$out/matrix.md"
  else
    test "$code" = 2
    grep -q '^SKIP:' "$out/matrix.md"
  fi
done

echo "credential-free Cloud matrix comparison passed"
