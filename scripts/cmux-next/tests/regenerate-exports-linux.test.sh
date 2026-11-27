#!/usr/bin/env bash
# The Linux generated-files job's settings regenerator keeps regenerate-*-exports.sh's contract (OUT holds the
# changed exports at their repository paths, one "regenerated: PATH" line each), which
# check-settings-exports.sh and base-autofix-exports-pack.sh read. The exporters are faked: a source
# file's lines become the exports' bytes.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/r"
mkdir -p "$repo/scripts/cmux-next" "$repo/docs/mdm" "$repo/schemas/settings" "$repo/plans/cmux-next"
cd "$repo" && git init -q -b feat
cp "$here/regenerate-settings-exports-linux.sh" scripts/cmux-next/
printf 'docs/mdm/a.json\nschemas/settings/s.json\n' > scripts/cmux-next/settings-exports.txt
# Fake settings exporter: writes every listed export from src.txt.
cat > scripts/cmux-next/export-settings-linux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 0 ]] || exit 2
while IFS= read -r p; do sed "s|^|$p:|" src.txt > "$p"; done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CMUX_SETTINGS_EXPORTS_LIST")
[[ ! -f extra ]] || echo x > docs/mdm/unlisted.json
SH
chmod +x scripts/cmux-next/*.sh
echo one > src.txt
CMUX_SETTINGS_EXPORTS_LIST=scripts/cmux-next/settings-exports.txt scripts/cmux-next/export-settings-linux.sh
git add -A && git commit -qm fresh

# Fresh: nothing regenerated, OUT empty.
out="$(scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o1")"
[[ -z "$out" ]] || fail "fresh settings printed: $out"
[[ -z "$(ls -A "$tmp/o1")" ]] || fail "fresh settings filled OUT"

# ALL=1: every listed export copied, fresh or not.
out="$(CMUX_SETTINGS_EXPORTS_ALL=1 scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o2")"
[[ "$out" == $'regenerated: docs/mdm/a.json\nregenerated: schemas/settings/s.json' ]] || fail "ALL=1 printed: $out"
cmp -s "$tmp/o2/docs/mdm/a.json" docs/mdm/a.json || fail "ALL=1 copy differs"

# Stale sources: every export changes, and OUT holds the new bytes.
echo two > src.txt
out="$(scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o3")"
[[ "$out" == $'regenerated: docs/mdm/a.json\nregenerated: schemas/settings/s.json' ]] || fail "stale settings printed: $out"
grep -qx 'docs/mdm/a.json:two' "$tmp/o3/docs/mdm/a.json" || fail "stale settings copy is not the new export"
git checkout -q -- . && echo one > src.txt

# A list of one (the base's list): only that export is written and reported.
printf 'docs/mdm/a.json\n' > "$tmp/one.txt"
echo three > src.txt
out="$(CMUX_SETTINGS_EXPORTS_LIST="$tmp/one.txt" scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o4")"
[[ "$out" == 'regenerated: docs/mdm/a.json' ]] || fail "one-file list printed: $out"
git checkout -q -- . && echo one > src.txt

# A write the list does not name fails; so does the Mac's bundle mode.
touch extra
if scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o5" 2>/dev/null; then fail "unlisted write passed"; fi
rm -f extra docs/mdm/unlisted.json
rc=0; scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/x.patch" 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail "bundle mode exited $rc, not 2"

# The action regenerator: the tool rewrites only changed files, yet a run that succeeded leaves every export newer
# than before it (base-autofix-exports-pack.sh refuses an export it did not see rewritten). swift and the catalog
# build are faked; the "tool" writes nothing, as on a base whose exports are already current.
cp "$here/regenerate-action-exports-linux.sh" scripts/cmux-next/
mkdir -p Packages/macOS/CmuxNext/LinuxActionExports "$tmp/bin"
: > Packages/macOS/CmuxNext/LinuxActionExports/sources.txt
printf '#!/usr/bin/env bash\nmkdir -p "$1/include"\n' > scripts/cmux-next/build-action-catalog-linux.sh
cat > "$tmp/bin/swift" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != --scratch-path ]]; do shift; done
mkdir -p "$2/debug" && printf '#!/usr/bin/env bash\nexit 0\n' > "$2/debug/cmux-next-action-exports" && chmod +x "$2/debug/cmux-next-action-exports"
SH
chmod +x scripts/cmux-next/*.sh "$tmp/bin/swift"
for f in action-surfaces.json action-catalog.json actions.md links.json; do echo x > "plans/cmux-next/$f"; done
git add -A && git commit -qm actions
marker="$tmp/marker"; : > "$marker"; sleep 1 # sleep-ok: an mtime-granularity tick
PATH="$tmp/bin:$PATH" scripts/cmux-next/regenerate-action-exports-linux.sh "$tmp/o6" > /dev/null
for f in action-surfaces.json action-catalog.json actions.md links.json; do
  [[ "plans/cmux-next/$f" -nt "$marker" ]] || fail "a current $f kept its old mtime: the base pack refuses it"
done
[[ -z "$(ls -A "$tmp/o6")" ]] || fail "current action exports filled OUT"
echo "regenerate-exports-linux: ok"
