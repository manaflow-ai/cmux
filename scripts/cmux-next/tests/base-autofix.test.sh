#!/usr/bin/env bash
# base-autofix.sh on a fixture repository: copies the regenerated files in,
# the action exports a Mac job regenerated among them (never a frozen path or a
# workflow file: GITHUB_TOKEN cannot push those),
# reports a missing cmux-tui tree input without writing it (its second list is
# a workflow's paths), and changes nothing when everything is current. No
# network, no git push.
set -euo pipefail
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
# The cmuxd-remote license review (--license-review): remote_daemon_notices.py check
# --update-review approves every allowed license and records it in review.json, so a Go
# dependency change never waits for a person. A refused license is left to one; the rest of
# the autofix still runs and the run stays green. The notices script and go are stubs here.
lic="$tmp/licenses"
mkdir -p "$lic/scripts" "$lic/daemon/remote/third-party/go" "$lic/scripts/cmux-next" "$tmp/go-bin"
echo '{"go": "old"}' > "$lic/daemon/remote/third-party/review.json"
echo old > "$lic/daemon/remote/third-party/go/LICENSE"
printf 'tree cmux-tui\n' > "$lic/scripts/cmux-next/cmux-tui-tree-inputs.txt"
cat > "$lic/scripts/remote_daemon_notices.py" <<'PY'
import os, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
pathlib.Path(os.environ["NOTICES_ARGS"]).write_text("\n".join(sys.argv[1:]) + "\n")
mode = os.environ.get("NOTICES_MODE", "approve")
if mode == "refuse":
    print("remote_daemon_notices: note: example.com/ok@v1.0.0: approved automatically (MIT)", file=sys.stderr)
    print("remote_daemon_notices: error: example.com/bad@v1.0.0: LICENSE is GPL-2.0-only, which is not allowed", file=sys.stderr)
    sys.exit(1)
if mode == "approve":
    (root / "daemon/remote/third-party/review.json").write_text('{"go": "new"}\n')
    (root / "daemon/remote/third-party/go/LICENSE").write_text("new\n")
print("remote_daemon_notices: every license cmuxd-remote links is allowed (3 modules, go1.26.0)")
PY
printf '#!/bin/sh\necho "go version go1.26.0"\n' > "$tmp/go-bin/go"; chmod +x "$tmp/go-bin/go"
git -C "$lic" init -q && git -C "$lic" add -A && git -C "$lic" -c user.name=t -c user.email=t@t commit -qm fixture
export NOTICES_ARGS="$tmp/notices-args"

PATH="$tmp/go-bin:$PATH" NOTICES_MODE=approve bash "$FIX" --no-fmt --license-review "$lic" > "$tmp/out" 2>&1 || fail "the license review must succeed"
grep -qx 'fixed: recorded the cmuxd-remote license review (daemon/remote/third-party/review.json)' "$tmp/out" || fail "a recorded review must be reported"
[[ "$(cat "$lic/daemon/remote/third-party/review.json")" == '{"go": "new"}' ]] || fail "review.json must be rewritten"
[[ "$(cat "$lic/daemon/remote/third-party/go/LICENSE")" == new ]] || fail "Go's license texts must be rewritten"
[[ "$(tr '\n' ' ' < "$NOTICES_ARGS")" == "check --daemon-root $lic/daemon/remote --update-review " ]] || fail "the review runs check --update-review on the checkout's daemon"
git -C "$lic" add -A && git -C "$lic" -c user.name=t -c user.email=t@t commit -qm recorded

# Every license already recorded: nothing changes, nothing is reported fixed.
PATH="$tmp/go-bin:$PATH" NOTICES_MODE=current bash "$FIX" --no-fmt --license-review "$lic" > "$tmp/out" 2>&1 || fail "a current review must succeed"
grep -q 'license review' "$tmp/out" && fail "a current review reports nothing"
[[ -z "$(git -C "$lic" status --porcelain)" ]] || fail "a current review changes nothing"

# A refused license: left to a person, with the script's own error line; exit 0.
PATH="$tmp/go-bin:$PATH" NOTICES_MODE=refuse bash "$FIX" --no-fmt --license-review "$lic" > "$tmp/out" 2>&1 || fail "a refused license must not fail the autofix"
grep -qx 'left: example.com/bad@v1.0.0: LICENSE is GPL-2.0-only, which is not allowed; a person decides' "$tmp/out" || fail "a refused license must be left with its error line"
grep -q '^fixed: recorded' "$tmp/out" && fail "a refused license records nothing"
[[ -z "$(git -C "$lic" status --porcelain)" ]] || fail "a refused license changes nothing"

# Without --license-review the script never runs.
rm -f "$NOTICES_ARGS"
PATH="$tmp/go-bin:$PATH" NOTICES_MODE=approve bash "$FIX" --no-fmt "$lic" > "$tmp/out" 2>&1 || fail "the fixer must succeed"
[[ ! -e "$NOTICES_ARGS" ]] || fail "the license review runs only with --license-review"
git -C "$lic" checkout -q -- .

# Without go on PATH the review is left, never failed.
nogo=""
IFS=: read -ra entries <<<"$PATH"
for entry in "${entries[@]}"; do [[ -x "$entry/go" ]] || nogo+="${nogo:+:}$entry"; done
if PATH="$nogo" command -v python3 >/dev/null && PATH="$nogo" command -v git >/dev/null; then
  PATH="$nogo" NOTICES_MODE=approve bash "$FIX" --no-fmt --license-review "$lic" > "$tmp/out" 2>&1 || fail "a missing go must not fail the autofix"
  grep -q '^left: the cmuxd-remote license review needs go' "$tmp/out" || fail "a missing go must be left"
  [[ -z "$(git -C "$lic" status --porcelain)" ]] || fail "a missing go changes nothing"
fi

# A frozen review is put back as it was and reported.
echo '{"go": "old"}' > "$lic/daemon/remote/third-party/review.json"
git -C "$lic" add -A && git -C "$lic" -c user.name=t -c user.email=t@t commit -qm stale
frozen_copy="$tmp/frozen/scripts"
mkdir -p "$frozen_copy/cmux-next" "$frozen_copy/ci"
cp "$FIX" "$ROOT_DIR/scripts/cmux-next/base-autofix-frozen.txt" "$frozen_copy/cmux-next/"
cp "$ROOT_DIR/scripts/ci/check_cmux_tui_tree_inputs.py" "$frozen_copy/ci/"
echo 'daemon/remote/third-party/*' >> "$frozen_copy/cmux-next/base-autofix-frozen.txt"
PATH="$tmp/go-bin:$PATH" NOTICES_MODE=approve bash "$frozen_copy/cmux-next/base-autofix.sh" --no-fmt --license-review "$lic" > "$tmp/out" 2>&1 || fail "a frozen review must not fail the autofix"
grep -q '^skipped (frozen): daemon/remote/third-party/review.json' "$tmp/out" || fail "a frozen review must be reported"
[[ -z "$(git -C "$lic" status --porcelain)" ]] || fail "a frozen review must be put back"
echo "base autofix: ok"
