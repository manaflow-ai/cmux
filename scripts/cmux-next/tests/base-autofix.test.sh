#!/usr/bin/env bash
# base-autofix.sh on a fixture repository: copies the regenerated files in
# (never a frozen path), adds a missing cmux-tui tree input to both lists, and
# changes nothing when everything is current. No network, no git push.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIX="$ROOT_DIR/scripts/cmux-next/base-autofix.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-base-autofix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2 2>/dev/null || true; exit 1; }

repo="$tmp/repo"; gen="$tmp/generated"
mkdir -p "$repo/cmux-tui/crates/x/src" "$repo/scripts/cmux-next" "$repo/.github/workflows" \
  "$repo/schemas/new" "$repo/Packages/macOS/CmuxNext" "$repo/plans/cmux-next" \
  "$gen/Packages/macOS/CmuxNext" "$gen/plans/cmux-next"
printf '[package]\nname = "x"\n' > "$repo/cmux-tui/crates/x/Cargo.toml"
printf 'pub const V: &str = include_str!("../../../../schemas/new/v.json");\n' > "$repo/cmux-tui/crates/x/src/lib.rs"
echo '{}' > "$repo/schemas/new/v.json"
printf 'tree cmux-tui\n' > "$repo/scripts/cmux-next/cmux-tui-tree-inputs.txt"
cat > "$repo/.github/workflows/cmux-tui-artifacts.yml" <<'YML'
on:
  pull_request_target:
    branches: [feat-cmux-next]
    paths:
      - "cmux-tui/**"
  workflow_dispatch:
YML
echo old > "$repo/Packages/macOS/CmuxNext/ci-target-graph.json"
echo old > "$repo/plans/cmux-next/actions.md"
echo new > "$gen/Packages/macOS/CmuxNext/ci-target-graph.json"
echo new > "$gen/plans/cmux-next/actions.md"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture

bash "$FIX" --no-fmt --generated "$gen" "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed"
[[ "$(cat "$repo/Packages/macOS/CmuxNext/ci-target-graph.json")" == new ]] || fail "a regenerated file must be copied in"
[[ "$(cat "$repo/plans/cmux-next/actions.md")" == old ]] || fail "a frozen path must never be written"
grep -q '^skipped (frozen): plans/cmux-next/actions.md' "$tmp/out" || fail "a skipped frozen path must be reported"
grep -qx 'blob schemas/new/v.json' "$repo/scripts/cmux-next/cmux-tui-tree-inputs.txt" || fail "the missing embed must be a tree input"
grep -q '^      - "schemas/new/v.json"$' "$repo/.github/workflows/cmux-tui-artifacts.yml" || fail "the missing embed must be an artifacts path"
grep -q '^  workflow_dispatch:' "$repo/.github/workflows/cmux-tui-artifacts.yml" || fail "the rest of the workflow must stay"

git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixed
bash "$FIX" --no-fmt --generated "$gen" "$repo" > "$tmp/out" 2>&1 || fail "a second run must succeed"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a current tree must stay unchanged"
echo "base autofix: ok"
