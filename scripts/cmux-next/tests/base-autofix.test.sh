#!/usr/bin/env bash
# base-autofix.sh on a fixture repository: copies the regenerated files in,
# the action exports a Mac job regenerated among them (never a frozen path or a
# workflow file: GITHUB_TOKEN cannot push those),
# reports a missing cmux-tui tree input without writing it (its second list is
# a workflow's paths), and changes nothing when everything is current. No
# network, no git push.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIX="$ROOT_DIR/scripts/cmux-next/base-autofix.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-base-autofix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2 2>/dev/null || true; exit 1; }

repo="$tmp/repo"; gen="$tmp/generated"
mkdir -p "$repo/cmux-tui/crates/x/src" "$repo/scripts/cmux-next" "$repo/.github/workflows" \
  "$repo/schemas/new" "$repo/Packages/macOS/CmuxNext" "$repo/plans/cmux-next" \
  "$gen/Packages/macOS/CmuxNext" "$gen/plans/cmux-next" "$gen/.github/workflows"
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
echo old > "$repo/plans/cmux-next/action-surfaces.json"
echo old > "$repo/Packages/macOS/CmuxNext/Package.swift"
echo new > "$gen/Packages/macOS/CmuxNext/ci-target-graph.json"
echo new > "$gen/plans/cmux-next/actions.md"
echo new > "$gen/plans/cmux-next/action-surfaces.json"
echo new > "$gen/Packages/macOS/CmuxNext/Package.swift"
echo 'on: push' > "$gen/.github/workflows/cmux-tui-artifacts.yml"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture

bash "$FIX" --no-fmt --generated "$gen" "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed"
[[ "$(cat "$repo/Packages/macOS/CmuxNext/ci-target-graph.json")" == new ]] || fail "a regenerated file must be copied in"
for export in actions.md action-surfaces.json; do
  [[ "$(cat "$repo/plans/cmux-next/$export")" == new ]] || fail "the regenerated action export $export must be copied in"
done
[[ "$(cat "$repo/Packages/macOS/CmuxNext/Package.swift")" == old ]] || fail "a frozen path must never be written"
grep -q '^skipped (frozen): Packages/macOS/CmuxNext/Package.swift' "$tmp/out" || fail "a skipped frozen path must be reported"
grep -q '^skipped (frozen): .github/workflows/cmux-tui-artifacts.yml' "$tmp/out" || fail "a regenerated workflow file must be skipped and reported"
grep -q '^left: cmux-tui tree input blob schemas/new/v.json' "$tmp/out" || fail "a missing tree input must be reported"
grep -q 'schemas/new' "$repo/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$repo/.github/workflows/cmux-tui-artifacts.yml" && fail "a missing tree input must not be written to either list"

git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixed
bash "$FIX" --no-fmt --generated "$gen" "$repo" > "$tmp/out" 2>&1 || fail "a second run must succeed"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a current tree must stay unchanged"
# Dependency order: the docs shortcuts and app-host files are rewritten from
# action-surfaces.json, so while the action exports are unverified (their Mac
# job failed or did not run on this tree) neither is regenerated from a
# possibly stale export: a branch that merged its base but kept a stale export
# lost the base's newer shortcuts that way.
mkdir -p "$repo/web/scripts" "$repo/web/data" "$repo/cmux-tui/crates/cmux-app-host/tools"
printf 'require("fs").writeFileSync("web/data/cmux-shortcuts.generated.json", "from-stale-export\\n")\n' > "$repo/web/scripts/export-docs-shortcuts.ts"
printf 'require("fs").writeFileSync("cmux-tui/crates/cmux-app-host/generated/scopes.json", "from-stale-export\\n")\n' > "$repo/cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts"
mkdir -p "$repo/cmux-tui/crates/cmux-app-host/generated"
echo current > "$repo/web/data/cmux-shortcuts.generated.json"
echo current > "$repo/cmux-tui/crates/cmux-app-host/generated/scopes.json"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm generators
bash "$FIX" --no-fmt --docs-shortcuts --app-host --unverified-exports "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed with unverified exports"
[[ "$(cat "$repo/web/data/cmux-shortcuts.generated.json")" == current ]] || fail "the docs shortcuts must wait for verified action exports"
[[ "$(cat "$repo/cmux-tui/crates/cmux-app-host/generated/scopes.json")" == current ]] || fail "the app-host files must wait for verified action exports"
grep -q '^left: web/data/cmux-shortcuts.generated.json' "$tmp/out" || fail "the waiting docs shortcuts must be reported"
# The base autofix rewrites the app-host files from the committed export
# anyway (app platform checks them against it): #32097 changed the operation
# catalog while the Mac exports were deferred, and app platform stayed red.
# The test runner has no bun: a stand-in runs the generator's one write.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho from-stale-export > cmux-tui/crates/cmux-app-host/generated/scopes.json\n' > "$tmp/fakebin/bun"
chmod +x "$tmp/fakebin/bun"
PATH="$tmp/fakebin:$PATH" bash "$FIX" --no-fmt --docs-shortcuts --app-host --app-host-committed-exports --unverified-exports "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed with committed app-host exports"
[[ "$(cat "$repo/web/data/cmux-shortcuts.generated.json")" == current ]] || fail "the docs shortcuts must still wait for verified action exports"
[[ "$(cat "$repo/cmux-tui/crates/cmux-app-host/generated/scopes.json")" == from-stale-export ]] || fail "the base app-host files must not wait for the Mac exports"
grep -q '^fixed: regenerated cmux-tui/crates/cmux-app-host/generated/scopes.json' "$tmp/out" || fail "the regenerated app-host file must be reported"
! grep -q '^left: cmux-tui/crates/cmux-app-host/generated' "$tmp/out" || fail "the base app-host files must not be reported as waiting"
git -C "$repo" checkout -q -- .
# The copies the app bundles follow the regenerated files (sync-app-runtime.sh): f2a158b55281
# regenerated scopes.json alone and left app platform red on base.
bundled=Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform
cp "$ROOT_DIR/scripts/cmux-next/sync-app-runtime.sh" "$repo/scripts/cmux-next/"
mkdir -p "$repo/cmux-tui/crates/cmux-app-host/schema/v2"
echo '{}' > "$repo/cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json"
(cd "$repo" && scripts/cmux-next/sync-app-runtime.sh >/dev/null)
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm bundled
PATH="$tmp/fakebin:$PATH" bash "$FIX" --no-fmt --app-host --app-host-committed-exports "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed syncing the bundled copies"
[[ "$(cat "$repo/$bundled/scopes.json")" == from-stale-export ]] || fail "the bundled scopes.json must follow the regenerated one"
grep -q "^fixed: synced $bundled/scopes.json" "$tmp/out" || fail "the synced bundled copy must be reported"
(cd "$repo" && scripts/cmux-next/sync-app-runtime.sh --check >/dev/null 2>&1) || fail "the bundled copies must be current after the fixer"
git -C "$repo" checkout -q -- .
# The read-only webviews job's patch may carry the rebuilt Chief memory
# inspector page (a stale one fails every webviews bundle build), but no other
# path outside webviews/.
page=Native/OptChat/optchat-chief/inspector/index.html
mkdir -p "$repo/$(dirname "$page")" "$repo/Native/OptChat/other" "$repo/webviews/src"
echo stale > "$repo/$page"; echo keep > "$repo/Native/OptChat/other/x.txt"; echo 'a  =1' > "$repo/webviews/src/a.ts"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm pages
echo rebuilt > "$repo/$page"; echo 'a = 1' > "$repo/webviews/src/a.ts"
git -C "$repo" diff --binary > "$tmp/fmt.patch"; git -C "$repo" checkout -q -- .
bash "$FIX" --no-fmt --webviews-fmt-patch "$tmp/fmt.patch" "$repo" > "$tmp/out" 2>&1 || fail "the fixer must apply the webviews patch"
[[ "$(cat "$repo/$page")" == rebuilt ]] || fail "the rebuilt inspector page must be applied"
[[ "$(cat "$repo/webviews/src/a.ts")" == 'a = 1' ]] || fail "the formatting in the same patch must be applied"
grep -q "^fixed: rebuilt $page" "$tmp/out" || fail "the rebuilt inspector page must be reported"
git -C "$repo" checkout -q -- .
echo changed > "$repo/Native/OptChat/other/x.txt"; echo rebuilt > "$repo/$page"
git -C "$repo" diff --binary > "$tmp/fmt.patch"; git -C "$repo" checkout -q -- .
bash "$FIX" --no-fmt --webviews-fmt-patch "$tmp/fmt.patch" "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed on a patch it refuses"
[[ "$(cat "$repo/Native/OptChat/other/x.txt")" == keep && "$(cat "$repo/$page")" == stale ]] || fail "a patch reaching another path outside webviews/ must apply nothing"
grep -q '^left: the webviews formatting patch reaches Native/OptChat/other/x.txt' "$tmp/out" || fail "the refused path must be reported"
# The namespace lint's safe rewrites land on base (a pull request only warns on
# them), except in a frozen file. A stand-in lint rewrites one file of each.
git -C "$repo" checkout -q -- .
settings=Packages/macOS/CmuxNext/Sources/CmuxNextSettings/S.swift
mkdir -p "$repo/Packages/a" "$repo/$(dirname "$settings")"
echo 'public enum A {}' > "$repo/Packages/a/A.swift"; echo 'public enum S {}' > "$repo/$settings"
cat > "$repo/scripts/lint-ios-package-conventions.sh" <<'SH'
[ "${1:-}" = --namespace-fix ] || exit 0
for f in Packages/a/A.swift Packages/macOS/CmuxNext/Sources/CmuxNextSettings/S.swift; do
  sed -i.bak 's/public enum \(.\) {}/public struct \1 { public init() {} }/' "$f" && rm -f "$f.bak"
done
exit 1
SH
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm namespaces
bash "$FIX" --no-fmt --ratchets "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed on namespace findings"
[[ "$(cat "$repo/Packages/a/A.swift")" == 'public struct A { public init() {} }' ]] || fail "a namespace finding must get the lint's safe rewrite"
[[ "$(cat "$repo/$settings")" == 'public enum S {}' ]] || fail "a frozen file must never get the namespace rewrite"
grep -q '^fixed: namespace rewrite in Packages/a/A.swift' "$tmp/out" || fail "the namespace rewrite must be reported"
grep -q "^skipped (frozen): $settings" "$tmp/out" || fail "a frozen namespace rewrite must be reported"
# A frozen file an earlier step already changed keeps that change and gets no rewrite.
git -C "$repo" checkout -q -- .
printf '// edited\npublic enum S {}\n' > "$repo/$settings"
bash "$FIX" --no-fmt --ratchets "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed beside an edited frozen file"
[[ "$(cat "$repo/$settings")" == $'// edited\npublic enum S {}' ]] || fail "an edited frozen file must keep its edit and get no rewrite"
grep -q "^skipped (frozen): $settings" "$tmp/out" || fail "a frozen namespace rewrite beside an edit must be reported"
# --sdk resyncs the SDKs' resource API descriptors after a catalog-only change
# (#34498 changed resource-operations-v2.json and left every catalog_sha256
# stale, a base red the PR could not fix: the descriptors are generated). The
# real sync script runs on a one-operation catalog.
git -C "$repo" checkout -q -- .
mkdir -p "$repo/cmux-tui/spec" "$repo/cmux-tui/bindings/rust/scripts"
cp "$ROOT_DIR/cmux-tui/bindings/rust/scripts/sync-resource-api.py" "$repo/cmux-tui/bindings/rust/scripts/"
for package in cpp go java python rust typescript zig; do mkdir -p "$repo/cmux-tui/bindings/$package"; done
printf '{"protocol":"p","operations":{"a.get":{"class":"read"}}}\n' > "$repo/cmux-tui/spec/resource-operations-v2.json"
python3 -I "$repo/cmux-tui/bindings/rust/scripts/sync-resource-api.py"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm descriptors
bash "$FIX" --no-fmt --sdk "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed on current descriptors"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "current descriptors must stay unchanged"
printf '{"protocol":"p","operations":{"a.get":{"class":"read","params":["id"]}}}\n' > "$repo/cmux-tui/spec/resource-operations-v2.json"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam catalog
bash "$FIX" --no-fmt --sdk "$repo" > "$tmp/out" 2>&1 || fail "the fixer must succeed on stale descriptors"
python3 -I "$repo/cmux-tui/bindings/rust/scripts/sync-resource-api.py" --check || fail "the descriptors must match the catalog after --sdk"
grep -q '^fixed: regenerated cmux-tui/bindings/zig/.cmux-resource-api.json' "$tmp/out" || fail "a resynced descriptor must be reported"
echo "base autofix: ok"
