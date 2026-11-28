#!/usr/bin/env bash
# The PR autofix regenerates the action exports (plans/cmux-next/action-surfaces.json,
# actions.md, links.json) so no pull request carries them by hand: a change to
# the action catalog or its exports turns the Mac `actions` repair on
# (autofix-areas.sh), and the push job's apply script (pr-autofix-apply.sh)
# accepts the regenerated exports but still refuses a workflow file. The
# app-host generated files (cmux-tui/crates/cmux-app-host/generated, read from
# the same export and the operation catalogs) are an autofix repair too. No network.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
AREAS="$ROOT_DIR/scripts/cmux-next/autofix-areas.sh"
APPLY="$ROOT_DIR/scripts/cmux-next/pr-autofix-apply.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pr-autofix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2 2>/dev/null || true; exit 1; }

area() { # changed path -> the actions area's value
  printf '%s\n' "$1" | bash "$AREAS" | sed -n 's/^actions=//p'
}
for path in Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionCatalog.swift \
  Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionCatalog.xcstrings \
  Packages/macOS/CmuxNext/Sources/CmuxNextActions/DeepLink/DeepLinkExport.swift \
  Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/CloudConfiguration.swift \
  plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json; do
  [[ "$(area "$path")" == true ]] || fail "a change to $path must regenerate the action exports"
done
[[ "$(area webviews/src/main.tsx)" == false ]] || fail "a webviews change must not start the Mac export job"
[[ "$(bash "$AREAS" --all | sed -n 's/^actions=//p')" == true ]] || fail "--all must include the action exports"
apphost() { printf '%s\n' "$1" | bash "$AREAS" | sed -n 's/^apphost=//p'; }
for path in cmux-tui/spec/resource-operations-v2.json backend/catalog/cloud-operations.json \
  plans/cmux-next/action-surfaces.json first-party-apps/notes/catalog.json \
  cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts cmux-tui/crates/cmux-app-host/generated/scopes.json; do
  [[ "$(apphost "$path")" == true ]] || fail "a change to $path must regenerate the app-host files"
done
[[ "$(apphost webviews/src/main.tsx)" == false ]] || fail "a webviews change must not regenerate the app-host files"

repo="$tmp/repo"
mkdir -p "$repo/plans/cmux-next" "$repo/web/data" "$repo/.github/workflows"
mkdir -p "$repo/cmux-tui/crates/cmux-app-host/generated"
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json \
  web/data/cmux-shortcuts.generated.json cmux-tui/crates/cmux-app-host/generated/scopes.json .github/workflows/x.yml; do
  echo old > "$repo/$file"
done
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json \
  web/data/cmux-shortcuts.generated.json cmux-tui/crates/cmux-app-host/generated/scopes.json; do
  echo new > "$repo/$file"
done
git -C "$repo" diff --binary > "$tmp/exports.patch"
git -C "$repo" checkout -q -- .
bash "$APPLY" "$tmp/exports.patch" "$repo" > "$tmp/out" 2>&1 || fail "the regenerated action exports must apply"
[[ "$(cat "$repo/plans/cmux-next/links.json")" == new ]] || fail "links.json must be applied"
[[ "$(cat "$repo/cmux-tui/crates/cmux-app-host/generated/scopes.json")" == new ]] || fail "the app-host files must be applied"
grep -q '^applied: plans/cmux-next/action-surfaces.json' "$tmp/out" || fail "the applied export must be reported"
git -C "$repo" checkout -q -- .

echo new > "$repo/.github/workflows/x.yml"
git -C "$repo" diff --binary > "$tmp/workflow.patch"
git -C "$repo" checkout -q -- .
bash "$APPLY" "$tmp/workflow.patch" "$repo" > "$tmp/out" 2>&1 && fail "a workflow file must be refused"
echo "pr autofix: ok"
