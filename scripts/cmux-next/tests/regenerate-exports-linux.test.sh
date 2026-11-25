#!/usr/bin/env bash
# The Linux generated-files job's regenerators keep regenerate-*-exports.sh's contract (OUT holds the
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
cp "$here/regenerate-settings-exports-linux.sh" "$here/regenerate-action-exports-catalog-linux.sh" scripts/cmux-next/
printf 'docs/mdm/a.json\nschemas/settings/s.json\n' > scripts/cmux-next/settings-exports.txt
# Fake settings/links exporter: writes every listed export (and links.json) from src.txt.
cat > scripts/cmux-next/export-settings-links-linux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == "--only settings" || "$1 $2" == "--only links" ]] || exit 2
if [[ "$2" == links ]]; then cp src.txt plans/cmux-next/links.json; exit 0; fi
while IFS= read -r p; do sed "s|^|$p:|" src.txt > "$p"; done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CMUX_SETTINGS_EXPORTS_LIST")
[[ ! -f extra ]] || echo x > docs/mdm/unlisted.json
SH
cat > scripts/cmux-next/export-action-surfaces-linux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for f in action-surfaces.json action-catalog.json actions.md; do sed "s|^|$f:|" src.txt > "plans/cmux-next/$f"; done
SH
chmod +x scripts/cmux-next/*.sh
echo one > src.txt
CMUX_SETTINGS_EXPORTS_LIST=scripts/cmux-next/settings-exports.txt scripts/cmux-next/export-settings-links-linux.sh --only settings
scripts/cmux-next/export-settings-links-linux.sh --only links
scripts/cmux-next/export-action-surfaces-linux.sh
git add -A && git commit -qm fresh

# Fresh: nothing regenerated, OUT empty.
out="$(scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o1")"
[[ -z "$out" ]] || fail "fresh settings printed: $out"
[[ -z "$(ls -A "$tmp/o1")" ]] || fail "fresh settings filled OUT"
out="$(scripts/cmux-next/regenerate-action-exports-catalog-linux.sh "$tmp/a1")"
[[ -z "$out" ]] || fail "fresh actions printed: $out"

# ALL=1: every listed export copied, fresh or not.
out="$(CMUX_SETTINGS_EXPORTS_ALL=1 scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o2")"
[[ "$out" == $'regenerated: docs/mdm/a.json\nregenerated: schemas/settings/s.json' ]] || fail "ALL=1 printed: $out"
cmp -s "$tmp/o2/docs/mdm/a.json" docs/mdm/a.json || fail "ALL=1 copy differs"

# Stale sources: every export changes, and OUT holds the new bytes.
echo two > src.txt
out="$(scripts/cmux-next/regenerate-settings-exports-linux.sh "$tmp/o3")"
[[ "$out" == $'regenerated: docs/mdm/a.json\nregenerated: schemas/settings/s.json' ]] || fail "stale settings printed: $out"
grep -qx 'docs/mdm/a.json:two' "$tmp/o3/docs/mdm/a.json" || fail "stale settings copy is not the new export"
out="$(scripts/cmux-next/regenerate-action-exports-catalog-linux.sh "$tmp/a3")"
[[ "$(grep -c '^regenerated: ' <<<"$out")" == 4 ]] || fail "stale actions printed: $out"
grep -qx 'actions.md:two' "$tmp/a3/plans/cmux-next/actions.md" || fail "stale actions copy is not the new export"
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
echo "regenerate-exports-linux: ok"
