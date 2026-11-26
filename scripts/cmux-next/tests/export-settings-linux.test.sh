#!/usr/bin/env bash
# scripts/cmux-next/export-settings-linux.sh against a scratch copy of the directories it reads:
#  - write then --check is fresh (0); a mutated settings source default makes exactly the exports
#    that carry it stale (1), with the default flipped in settings-schema.json and the MDM manifest;
#  - a catalog key the sources name and the catalog lacks is "cannot decide" (2).
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
pkg=Packages/macOS/CmuxNext
for rel in schemas/settings scripts/cmux-next/linux-exports docs/mdm \
  "$pkg/Sources/CmuxNextSettings" "$pkg/Sources/CmuxNextDesign" "$pkg/Sources/CmuxNextDesignTokens" \
  scripts/cmux-next/settings-exports.txt scripts/cmux-next/export-settings-linux.sh; do
  mkdir -p "$repo/$(dirname "$rel")"
  cp -R "$src/$rel" "$repo/$rel"
done
rm -rf "$repo/scripts/cmux-next/linux-exports/__pycache__"
git -C "$repo" init -q
run() { "$repo/scripts/cmux-next/export-settings-linux.sh" "$@"; }

# The copy's catalog gets every key the sources name, so the strict export can run whatever this
# tree's catalog lacks (that case is checked below on its own).
python3 -I - "$repo" <<'PY'
import json, os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts/cmux-next/linux-exports"))
import settings_schema
schema = settings_schema.Schema(root)
schema.document(strict=False)
path = os.path.join(root, settings_schema.CATALOG)
data = json.load(open(path, encoding="utf-8"))
for key in schema.missing:
    data["strings"][key] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY

run >/dev/null || fail "write exited $?"
run --check || fail "--check after a write is not fresh"

cp "$repo/schemas/settings/source/agent-cache.json" "$tmp/agent-cache.json"
python3 -I - "$repo/schemas/settings/source/agent-cache.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
row = data["lists"][0]["rows"][0]
assert row["key"] == "agents.cacheCompact.enabled" and row["default"] is True, row["key"]
row["default"] = False
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
set +e; run --check 2>"$tmp/stale"; code=$?; set -e
[ "$code" = 1 ] || fail "--check after a source change exited $code, not 1"
grep -qx "stale: schemas/settings/settings-schema.json" "$tmp/stale" || fail "settings-schema.json not listed stale: $(cat "$tmp/stale")"
grep -qx "stale: docs/mdm/com.manaflow.cmux.plist" "$tmp/stale" || fail "the MDM manifest not listed stale: $(cat "$tmp/stale")"
run >/dev/null
python3 -I - "$repo" <<'PY'
import json, os, sys
root = sys.argv[1]
rows = json.load(open(os.path.join(root, "schemas/settings/settings-schema.json")))["rows"]
row = next(r for r in rows if r["key"] == "agents.cacheCompact.enabled")
assert row["default"] is False, row["default"]
manifest = open(os.path.join(root, "docs/mdm/com.manaflow.cmux.plist")).read()
at = manifest.index("<string>agents.cacheCompact.enabled</string>")
entry = manifest[manifest.rfind("<dict>", 0, at):manifest.index("</dict>", at)]
assert "<key>pfm_default</key>\n\t\t\t<false/>" in entry, entry
PY
cp "$tmp/agent-cache.json" "$repo/schemas/settings/source/agent-cache.json"
run --check 2>/dev/null && fail "the reverted source should leave the written exports stale"
run >/dev/null
run --check || fail "reverting the source does not return to fresh"


python3 -I - "$repo" <<'PY'
import json, os, sys
path = os.path.join(sys.argv[1], "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings")
data = json.load(open(path, encoding="utf-8"))
del data["strings"]["settings.agents.cacheCompact.enabled"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
set +e; run --check 2>/dev/null; code=$?; set -e
[ "$code" = 2 ] || fail "a missing catalog key exited $code, not 2"
echo "ok: export-settings-linux"
