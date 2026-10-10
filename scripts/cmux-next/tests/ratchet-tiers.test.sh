#!/usr/bin/env bash
# The style ratchets' warning tier: a god type, an l10n style error or a custom
# scrollbar under its ceiling (GODFILES_WARN_SLACK, L10N_STYLE_WARN_MAX,
# SCROLLBARS_WARN_MAX) warns as ratchet debt and passes; over it, it fails.
# Unset, every hit fails as before. Placeholder and table errors always fail.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ratchet-tiers.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- God types: a type of N lines over three files of module Fixture.
god_repo() { # total-lines
  local repo="$tmp/god" dir per i f
  rm -rf "$repo"; dir="$repo/Packages/macOS/CmuxNext/Sources/Fixture"; mkdir -p "$dir"
  git -C "$repo" init -q
  per=$(( $1 / 3 ))
  for f in 0 1 2; do
    { if (( f == 0 )); then echo "final class Big {"; else echo "extension Big {"; fi
      for (( i = 0; i < per - 2; i++ )); do echo "    var v${f}_$i: Int { $i }"; done
      echo "}"; } > "$dir/Big$f.swift"
  done
  echo "$repo/Packages/macOS/CmuxNext"
}
god() { # env-assignments... total-lines -> exit status; output in $tmp/out
  local total="${*: -1}" pkg
  pkg="$(god_repo "$total")"
  env "${@:1:$#-1}" bash "$ROOT_DIR/scripts/cmux-next/check-no-godfiles.sh" --only swift "$pkg" > "$tmp/out" 2>&1
}
god 1110 && fail "a 1110-line type must fail without GODFILES_WARN_SLACK"
god GODFILES_WARN_SLACK=20 1110 || { cat "$tmp/out"; fail "a 1110-line type must only warn under a 1200-line ceiling"; }
grep -q '^::warning title=ratchet debt::.*god type.*Fixture/Big' "$tmp/out" || { cat "$tmp/out"; fail "the warned god type must be a ratchet debt annotation"; }
god GODFILES_WARN_SLACK=20 1290 && fail "a 1290-line type must fail over a 1200-line ceiling"
grep -q 'over the hard ceiling of 1200' "$tmp/out" || { cat "$tmp/out"; fail "a failure over the ceiling must name the ceiling"; }

# --- l10n: one table of every language with English "Hello %@".
l10n() { # env-assignments... -- python-edit -> exit status; output in $tmp/out
  local repo="$tmp/l10n" edit
  edit="${*: -1}"
  rm -rf "$repo"; mkdir -p "$repo/Packages/macOS/CmuxNext/Sources/Fixture" "$repo/Resources"
  python3 - "$repo" "$edit" "$ROOT_DIR/scripts/cmux-next/check-l10n.sh" <<'PY'
import json, re, sys, pathlib
repo, edit, check = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3]).read_text()
langs = re.findall(r'"([a-zA-Z-]+)"', re.search(r'LANGS = \((.*?)\)', check, re.S)[1])
def table(keys):
    strings = {}
    for key in keys:
        strings[key] = {"localizations": {l: {"stringUnit": {"state": "translated", "value": "Hello %@"}} for l in langs}}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
main = table(["a", "b", "c"])
exec(edit, {"t": main["strings"]})
(repo / "Packages/macOS/CmuxNext/Sources/Fixture/Localizable.xcstrings").write_text(json.dumps(main))
(repo / "Resources/InfoPlist.xcstrings").write_text(json.dumps(table([])))
PY
  env "${@:1:$#-1}" bash "$ROOT_DIR/scripts/cmux-next/check-l10n.sh" "$repo" > "$tmp/out" 2>&1
}
missing_one='del t["a"]["localizations"]["de"]'
missing_two='del t["a"]["localizations"]["de"]; del t["b"]["localizations"]["fr"]'
placeholder='t["c"]["localizations"]["ja"]["stringUnit"]["value"] = "Hello %d"'
l10n "$missing_one" && fail "a missing language must fail without L10N_STYLE_WARN_MAX"
l10n L10N_STYLE_WARN_MAX=1 "$missing_one" || { cat "$tmp/out"; fail "one missing language must only warn under a ceiling of 1"; }
grep -q '^::warning title=ratchet debt::.*a: missing de' "$tmp/out" || { cat "$tmp/out"; fail "the warned l10n style error must be a ratchet debt annotation"; }
l10n L10N_STYLE_WARN_MAX=1 "$missing_two" && fail "two missing languages must fail over a ceiling of 1"
l10n L10N_STYLE_WARN_MAX=99 "$placeholder" && fail "a placeholder mismatch must fail under any ceiling"

# --- Scrollbars: N custom web scrollbars.
scroll() { # env-assignments... count -> exit status; output in $tmp/out
  local repo="$tmp/scroll" n="${*: -1}" i
  rm -rf "$repo"; mkdir -p "$repo/webviews/src/fixture"
  for (( i = 0; i < n; i++ )); do echo ".list$i { scrollbar-width: none; }"; done > "$repo/webviews/src/fixture/styles.css"
  env "${@:1:$#-1}" bash "$ROOT_DIR/scripts/cmux-next/check-scrollbars.sh" "$repo" > "$tmp/out" 2>&1
}
scroll 1 && fail "a custom scrollbar must fail without SCROLLBARS_WARN_MAX"
scroll SCROLLBARS_WARN_MAX=1 1 || { cat "$tmp/out"; fail "one custom scrollbar must only warn under a ceiling of 1"; }
grep -q '^::warning title=ratchet debt::.*styles.css:1' "$tmp/out" || { cat "$tmp/out"; fail "the warned scrollbar must be a ratchet debt annotation"; }
scroll SCROLLBARS_WARN_MAX=1 2 && fail "two custom scrollbars must fail over a ceiling of 1"

echo "ratchet tiers: ok"
