#!/usr/bin/env bash
# check-l10n.sh's count agreement rule: a CmuxNext key whose English writes a
# word right after an integer count fails unless it has plural variations or an
# entry (current English, a reason) in l10n-count-noun-allowlist.json; a stale
# entry fails; and a plural key looked up without its count (a String(format:)
# after the lookup) fails, while an interpolated literal or a
# Bundle.localizedString(forKey:...) call passes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-l10n-count-noun.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# run <python-edit> -> exit status of check-l10n.sh on a fixture repo; output in $tmp/out.
# The edit sees `t` (the table's strings), `plural(key, one, other)`, `allow` (the
# allowlist dict) and `swift` (a list of Swift source lines for Fixture/Strings.swift).
run() {
  local repo="$tmp/repo"
  rm -rf "$repo"; mkdir -p "$repo/Packages/macOS/CmuxNext/Sources/Fixture" "$repo/Resources" "$repo/scripts/cmux-next"
  python3 - "$repo" "$1" "$ROOT_DIR/scripts/cmux-next/check-l10n.sh" <<'PY'
import json, re, sys, pathlib
repo, edit, check = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3]).read_text()
langs = re.findall(r'"([a-zA-Z-]+)"', re.search(r'LANGS = \((.*?)\)', check, re.S)[1])
def unit(value): return {"stringUnit": {"state": "translated", "value": value}}
t = {"plain": {"localizations": {l: unit("Hello %@") for l in langs}}}
def put(key, value): t[key] = {"localizations": {l: unit(value) for l in langs}}
def plural(key, one, other):
    t[key] = {"localizations": {l: {"variations": {"plural": {"one": unit(one), "other": unit(other)}}} for l in langs}}
allow, swift = {}, []
exec(edit, {"t": t, "put": put, "plural": plural, "allow": allow, "swift": swift})
sources = repo / "Packages/macOS/CmuxNext/Sources/Fixture"
(sources / "Localizable.xcstrings").write_text(json.dumps({"sourceLanguage": "en", "strings": t, "version": "1.0"}))
(sources / "Strings.swift").write_text("\n".join(swift) + "\n")
(repo / "Resources/InfoPlist.xcstrings").write_text(json.dumps({"sourceLanguage": "en", "strings": {}, "version": "1.0"}))
(repo / "scripts/cmux-next/l10n-count-noun-allowlist.json").write_text(json.dumps(allow))
PY
  bash "$ROOT_DIR/scripts/cmux-next/check-l10n.sh" "$repo" > "$tmp/out" 2>&1
}

run 'put("files.items", "%lld items")' && { cat "$tmp/out"; fail "a word after a count without plural variations must fail"; }
grep -q 'files.items: a word follows the count' "$tmp/out" || { cat "$tmp/out"; fail "the failure must name the key"; }
run 'plural("files.items", "%lld item", "%lld items")' || { cat "$tmp/out"; fail "a key with plural variations must pass"; }
run 'put("files.items", "Items: %lld")' || { cat "$tmp/out"; fail "a label before the count must pass"; }
run 'put("find.position", "%1$lld of %2$lld"); allow["find.position"] = {"source": "%1$lld of %2$lld", "reason": "a preposition"}' \
  || { cat "$tmp/out"; fail "an allowlisted key with its current English and a reason must pass"; }
run 'put("find.position", "%1$lld of %2$lld total"); allow["find.position"] = {"source": "%1$lld of %2$lld", "reason": "a preposition"}' \
  && { cat "$tmp/out"; fail "an allowlist entry whose English changed must fail"; }
run 'allow["gone"] = {"source": "%lld gone", "reason": "x"}' && { cat "$tmp/out"; fail "a stale allowlist entry must fail"; }
grep -q 'gone no longer writes a word after a count' "$tmp/out" || { cat "$tmp/out"; fail "the stale entry must be named"; }

plural_key='plural("files.items", "%lld item", "%lld items"); '
run "$plural_key"'swift.append("let a = String(format: String(localized: \"files.items\", defaultValue: \"%lld items\"), n)")' \
  && { cat "$tmp/out"; fail "a plural key looked up without its count must fail"; }
grep -q 'Strings.swift:1: plural key files.items is looked up without its count' "$tmp/out" || { cat "$tmp/out"; fail "the call site must be named"; }
run "$plural_key"'swift.append("let a = String(localized: \"files.items\", defaultValue: \"\\(n) items\")")' \
  || { cat "$tmp/out"; fail "an interpolated lookup must pass"; }
run "$plural_key"'swift.append("let a = Bundle.module.localizedString(forKey: \"files.items\", value: \"%lld items\", table: nil,")' \
  || { cat "$tmp/out"; fail "a Bundle.localizedString(forKey:) lookup must pass"; }
echo "check-l10n count agreement: ok"
