#!/usr/bin/env bash
# regenerate-action-exports.sh hands a lane without a Mac one patch of the exports that changed:
# OUT.patch, beside OUT, which `cmux-ci run --artifact .build/exports.patch` returns. A fleet step
# returns one file, and a pull request that changes the catalog stales action-surfaces.json and
# actions.md together (cmux#38644, 2026-11-09: its Linux lane had no way to regenerate them).
# swift is a stub that writes the exports the way ActionSurfaceParityTests does.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
surfaces=plans/cmux-next/action-surfaces.json
md=plans/cmux-next/actions.md
links=plans/cmux-next/links.json

repo="$tmp/repo"
mkdir -p "$repo/scripts/cmux-next/lib" "$repo/scripts/ci" "$repo/Packages/macOS/CmuxNext" "$repo/plans/cmux-next" "$tmp/bin"
cp "$src/scripts/cmux-next/regenerate-action-exports.sh" "$repo/scripts/cmux-next/"
cp "$src/scripts/cmux-next/lib/fleet-only.sh" "$src/scripts/cmux-next/lib/warm-swiftpm.sh" "$repo/scripts/cmux-next/lib/"
cp "$src/scripts/ci/swift-test-debug-info.sh" "$src/scripts/ci/swiftpm-binary-module-guard.sh" "$repo/scripts/ci/"
echo '// swift-tools-version:6.0' > "$repo/Packages/macOS/CmuxNext/Package.swift"
printf '{"actions": ["old"]}\n' > "$repo/$surfaces"
printf '# Actions\nold\n' > "$repo/$md"
printf '{"links": []}\n' > "$repo/$links"
printf '.build/\n' > "$repo/.gitignore"
git -C "$repo" init -q -b feat
git -C "$repo" add -A
git -C "$repo" commit -q -m base

# The stub: `swift test` with CMUX_UPDATE_ACTION_SURFACES=1 writes STUB_SURFACES and STUB_MD into the
# exports (cwd is the package); `swift build` does nothing.
cat > "$tmp/bin/swift" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == test && "${CMUX_UPDATE_ACTION_SURFACES:-}" == 1 ]] || exit 0
root="$(git rev-parse --show-toplevel)"
printf '%s\n' "$STUB_SURFACES" > "$root/plans/cmux-next/action-surfaces.json"
printf '%s\n' "$STUB_MD" > "$root/plans/cmux-next/actions.md"
STUB
chmod +x "$tmp/bin/swift"

run() { # <surfaces> <md>
  (cd "$repo" && PATH="$tmp/bin:$PATH" CMUX_CI_STEP_KEY=t STUB_SURFACES="$1" STUB_MD="$2" \
    bash scripts/cmux-next/regenerate-action-exports.sh .build/exports)
}

# 1. Both exports changed: OUT holds their copies (base-autofix.sh's input, unchanged), and
#    OUT.patch, outside OUT, applies to a clean checkout of the same commit and yields both.
run '{"actions": ["old", "devices.setup"]}' $'# Actions\nold\ndevices.setup' > "$tmp/out" 2>&1 || fail "the regeneration failed: $(cat "$tmp/out")"
[[ -f "$repo/.build/exports/$surfaces" && -f "$repo/.build/exports/$md" ]] || fail "OUT lacks the changed exports: $(cat "$tmp/out")"
[[ ! -e "$repo/.build/exports/$links" ]] || fail "OUT holds an export that did not change"
[[ -s "$repo/.build/exports.patch" ]] || fail "no OUT.patch: $(cat "$tmp/out")"
[[ -z "$(find "$repo/.build/exports" -name '*.patch')" ]] || fail "the patch is inside OUT, where base-autofix.sh would commit it"
grep -q '^patch: .*exports.patch' "$tmp/out" || fail "the log does not name the patch: $(cat "$tmp/out")"
git clone -q "$repo" "$tmp/lane"
git -C "$tmp/lane" apply --allow-empty "$repo/.build/exports.patch" || fail "the patch does not apply to a clean checkout"
cmp -s "$tmp/lane/$surfaces" "$repo/$surfaces" || fail "the patched action-surfaces.json differs from the regenerated one"
cmp -s "$tmp/lane/$md" "$repo/$md" || fail "the patched actions.md differs from the regenerated one"
[[ "$(git -C "$tmp/lane" diff --name-only | LC_ALL=C sort | tr '\n' ' ')" == "$(printf '%s\n' "$md" "$surfaces" | LC_ALL=C sort | tr '\n' ' ')" ]] || fail "the patch touches other files: $(git -C "$tmp/lane" diff --name-only)"

# 2. Nothing changed: the patch holds no diff (an earlier run's patch is not handed over again), yet
#    is not an empty file: the fleet's artifact store refuses a 0-byte artifact (cache_http_400; step
#    70f3a60755bda32f6b5e4280 at cmux#38644's head, 2026-11-09), which failed the step. The lane
#    command in the script's header (`git apply --allow-empty`) succeeds on it and changes nothing.
git -C "$repo" checkout -q -- plans
run '{"actions": ["old"]}' $'# Actions\nold' > "$tmp/out" 2>&1 || fail "the clean regeneration failed: $(cat "$tmp/out")"
[[ -s "$repo/.build/exports.patch" ]] || fail "a run with no change left an empty file, which the artifact store refuses"
! grep -q '^diff --git' "$repo/.build/exports.patch" || fail "a run with no change left a diff in the patch"
[[ -z "$(find "$repo/.build/exports" -type f)" ]] || fail "a run with no change left exports in OUT"
git -C "$tmp/lane" checkout -q -- plans
git -C "$tmp/lane" apply --allow-empty "$repo/.build/exports.patch" || fail "the lane command fails on a patch with no diff"
[[ -z "$(git -C "$tmp/lane" status --porcelain)" ]] || fail "the lane command changed files for an empty patch"

echo "regenerate-action-exports.test.sh: ok"
