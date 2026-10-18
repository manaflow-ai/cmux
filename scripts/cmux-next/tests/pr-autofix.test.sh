#!/usr/bin/env bash
# The PR autofix regenerates the action exports (plans/cmux-next/action-surfaces.json,
# actions.md, links.json) so no pull request carries them by hand: a change to
# the action catalog or its exports turns the Mac `actions` repair on
# (autofix-areas.sh), and the push job's apply script (pr-autofix-apply.sh)
# accepts the regenerated exports but still refuses a workflow file. The
# app-host generated files (cmux-tui/crates/cmux-app-host/generated, read from
# the same export and the operation catalogs) are an autofix repair too, and so
# are the settings exports a CmuxNextSettings change needs. No network.
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
# The settings exports (schemas/settings/settings-schema.json, the source stamp,
# docs/mdm) follow a CmuxNextSettings change on the same Mac job, so a pull
# request that adds a setting lands with them instead of a red defaults-snapshot.
settings() { printf '%s\n' "$1" | bash "$AREAS" | sed -n 's/^settings=//p'; }
for path in Packages/macOS/CmuxNext/Sources/CmuxNextSettings/CmuxConfigSnapshot.swift \
  Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings schemas/settings/settings-schema.json; do
  [[ "$(settings "$path")" == true ]] || fail "a change to $path must regenerate the settings exports"
done
[[ "$(settings webviews/src/main.tsx)" == false ]] || fail "a webviews change must not regenerate the settings exports"

repo="$tmp/repo"
mkdir -p "$repo/plans/cmux-next" "$repo/web/data" "$repo/.github/workflows"
mkdir -p "$repo/cmux-tui/crates/cmux-app-host/generated"
mkdir -p "$repo/schemas/settings" "$repo/schemas/settings-export" "$repo/docs/mdm"
settings_exports=(schemas/settings/settings-schema.json schemas/settings-export/settings-schema.sources.sha256
  docs/mdm/com.manaflow.cmux.json docs/mdm/managed-preferences.md)
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json \
  web/data/cmux-shortcuts.generated.json cmux-tui/crates/cmux-app-host/generated/scopes.json .github/workflows/x.yml \
  "${settings_exports[@]}"; do
  echo old > "$repo/$file"
done
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json \
  web/data/cmux-shortcuts.generated.json cmux-tui/crates/cmux-app-host/generated/scopes.json "${settings_exports[@]}"; do
  echo new > "$repo/$file"
done
git -C "$repo" diff --binary > "$tmp/exports.patch"
git -C "$repo" checkout -q -- .
bash "$APPLY" "$tmp/exports.patch" "$repo" > "$tmp/out" 2>&1 || fail "the regenerated action exports must apply"
[[ "$(cat "$repo/plans/cmux-next/links.json")" == new ]] || fail "links.json must be applied"
[[ "$(cat "$repo/cmux-tui/crates/cmux-app-host/generated/scopes.json")" == new ]] || fail "the app-host files must be applied"
grep -q '^applied: plans/cmux-next/action-surfaces.json' "$tmp/out" || fail "the applied export must be reported"
for file in "${settings_exports[@]}"; do
  [[ "$(cat "$repo/$file")" == new ]] || fail "the settings export $file must be applied"
done
git -C "$repo" checkout -q -- .

echo new > "$repo/.github/workflows/x.yml"
git -C "$repo" diff --binary > "$tmp/workflow.patch"
git -C "$repo" checkout -q -- .
bash "$APPLY" "$tmp/workflow.patch" "$repo" > "$tmp/out" 2>&1 && fail "a workflow file must be refused"

# A formatter patch is produced from the merge tree but applied to the exact
# PR head. The functional file must survive that handoff, and the repair
# commit must have the PR head as its parent. This guards against a collapsed
# formatter-only autofix commit.
fixture="$tmp/ancestry"
mkdir -p "$fixture/webviews" "$fixture/src"
printf 'const functional = "PR behavior";\n' > "$fixture/src/feature.ts"
printf 'const formatted = 1;\n' > "$fixture/webviews/App.tsx"
git -C "$fixture" init -q
git -C "$fixture" add -A
git -C "$fixture" -c user.name=t -c user.email=t@t commit -qm base
printf 'const functional = "PR behavior + test";\n' > "$fixture/src/feature.ts"
git -C "$fixture" add src/feature.ts
git -C "$fixture" -c user.name=t -c user.email=t@t commit -qm pr
head_sha="$(git -C "$fixture" rev-parse HEAD)"
printf 'const formatted = 2;\n' > "$fixture/webviews/App.tsx"
git -C "$fixture" diff --binary -- webviews/App.tsx > "$tmp/formatter.patch"
git -C "$fixture" checkout -q -- .
bash "$APPLY" "$tmp/formatter.patch" "$fixture" > "$tmp/out" 2>&1 || fail "the formatter patch must apply to the PR head"
git -C "$fixture" add -A
git -C "$fixture" -c user.name=t -c user.email=t@t.com commit -qm autofix
[[ "$(git -C "$fixture" rev-parse HEAD^)" == "$head_sha" ]] || fail "autofix parent must remain the exact PR head"
grep -q 'PR behavior + test' "$fixture/src/feature.ts" || fail "autofix must preserve the PR functional file"
echo "pr autofix: ok"
