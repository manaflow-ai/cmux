#!/usr/bin/env bash
# pin-cmux-tui.sh resolve-newest-published with CMUX_TUI_TREE_PROBE_CACHE: the
# nightly-next tick calls request-nightly-next.sh once per unpublished commit,
# and each call re-ran the same search: tick 45774766096's request step took
# 366 s for 5 commits (46-87 s each), every call recomputing three tree keys
# per commit and re-reading the same absent trees from the CDN. With the cache
# a later call in the same job reuses the keys and the verdicts, and resolves
# the same tree. An absent verdict expires (CMUX_TUI_TREE_PROBE_CACHE_TTL), so
# a tree published meanwhile is still found. No network: a stub curl serves the CDN.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# git_q, and no background git maintenance in the scratch repositories.
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$ROOT/scripts/cmux-next/tests/lib/git-fixture.sh"
fail() { printf '%s\n' "$@" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
bin=cmux-tui-aarch64-apple-darwin

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo one > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
change() { # <cmux-tui/a content> <message> -> commit sha
  echo "$1" > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "$2"; git -C "$src" rev-parse HEAD; }
old=$(git -C "$src" rev-parse HEAD)
published=$(change two "tui two (published)")
mismatch=$(change three "tui three (manifest disagrees)")
echo app > "$src/App.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "app only"
tip=$(change four "tui four (superseded, never published)")
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$1" 2>/dev/null); }

cdn="$TMP/cdn"
publish() { # <commit> <manifest sha override or empty>
  local k; k=$(key "$1")
  mkdir -p "$cdn/tree/$k" "$cdn/$1"
  echo "build of $1" > "$cdn/tree/$k/$bin"
  sha "$cdn/tree/$k/$bin" > "$cdn/tree/$k/$bin.sha256"
  printf '{"key": "%s", "commit": "%s"}\n' "$k" "$1" > "$cdn/tree/$k/source.json"
  printf '{"commit": "%s", "binaries": {"%s": "%s"}}\n' "$1" "$bin" "${2:-$(sha "$cdn/tree/$k/$bin")}" > "$cdn/$1/manifest.json"
}
publish "$published" ""
publish "$mismatch" "$(printf '0%.0s' {1..64})"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time|-w) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
echo "\$url" >> "$TMP/curl.log"
# GitHub's Actions API: runs by head_sha, jobs by run id (logged; the resolver must not call it).
case "\$url" in
  https://api.github.com/*/actions/workflows/cmux-next.yml/runs\?*)
    sha="\${url##*head_sha=}"; sha="\${sha%%&*}"
    cat "$TMP/api/runs-\$sha.json" 2>/dev/null || echo '{"workflow_runs": []}'; exit 0 ;;
  https://api.github.com/*/actions/runs/*/jobs\?*)
    id="\${url%%/jobs\?*}"; id="\${id##*/}"
    cat "$TMP/api/jobs-\$id.json" 2>/dev/null || exit 22; exit 0 ;;
esac
path="\${url#https://files.cmux.com/cmux-tui/}"; path="\${path%%\?*}"
[[ "\$path" != "\$url" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
chmod +x "$TMP/bin/curl"

resolve() { # [env...] -> stdout+stderr in $out, exit in $status
  status=0
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT PATH="$TMP/bin:$PATH" CMUX_TUI_TREE_WAIT_SECONDS=2700 "$@" \
    bash scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published 2>"$TMP/err") || status=$?
  err=$(cat "$TMP/err")
}

tree_reads() { grep -c '/cmux-tui/tree/' "$TMP/curl.log" 2>/dev/null || true; }
cache="$TMP/probe-cache"

# First call fills the cache.
: > "$TMP/curl.log"
resolve CMUX_TUI_TREE_PROBE_CACHE="$cache"
[[ "$status" == 0 ]] || fail "first cached resolve failed (exit $status):" "$out" "$err"
first="$out"
grep -qx "commit=$published" <<<"$out" || fail "expected commit=$published, got:" "$out" "$err"
cold=$(tree_reads)
(( cold > 0 )) || fail "the first call must probe the CDN"

# Second call: same answer, no tree re-read, no key recomputed.
: > "$TMP/curl.log"
cat > "$TMP/bin/python3" <<STUB
#!/usr/bin/env bash
case "\$*" in *cmux_tui_tree_key.py*) echo "\$*" >> "$TMP/keys.log" ;; esac
exec $(command -v python3) "\$@"
STUB
chmod +x "$TMP/bin/python3"
: > "$TMP/keys.log"
resolve CMUX_TUI_TREE_PROBE_CACHE="$cache"
[[ "$status" == 0 ]] || fail "second cached resolve failed (exit $status):" "$out" "$err"
grep -qx "commit=$published" <<<"$out" && grep -qx "key=$(key "$published")" <<<"$out" \
  && grep -qx "source_commit=$published" <<<"$out" || fail "a cached good verdict must give the same commit and key:" "$out" "$err"
[[ "$(grep -v '^behind_hours=' <<<"$out")" == "$(grep -v '^behind_hours=' <<<"$first")" ]] \
  || fail "the cached call's output differs:" "$first" "---" "$out"
[[ "$(tree_reads)" == 0 ]] || fail "the cached call re-read $(tree_reads) tree URLs (cold call: $cold):" "$(cat "$TMP/curl.log")"
# Only the tip's own key (tip_key=) may be computed again; no walked commit's.
keys=$(wc -l < "$TMP/keys.log")
(( keys <= 1 )) || fail "the cached call recomputed $keys tree keys:" "$(cat "$TMP/keys.log")"
rm -f "$TMP/bin/python3"

# A tree published after the first call: a fresh absent verdict still holds,
# an expired one (TTL 0) is re-probed and the newer tree wins.
publish "$tip" ""
resolve CMUX_TUI_TREE_PROBE_CACHE="$cache"
grep -qx "commit=$published" <<<"$out" || fail "within the TTL the absent verdict holds, got:" "$out" "$err"
resolve CMUX_TUI_TREE_PROBE_CACHE="$cache" CMUX_TUI_TREE_PROBE_CACHE_TTL=0
[[ "$status" == 0 ]] && grep -qx "commit=$tip" <<<"$out" || fail "an expired absent verdict must be re-probed and find $tip (exit $status):" "$out" "$err"

# Off unless asked (the tick sets it through GITHUB_WORKFLOW_REF): nothing written.
other="$TMP/unused-cache"
resolve CMUX_TUI_TREE_PROBE_CACHE=""
[[ "$status" == 0 ]] && grep -qx "commit=$tip" <<<"$out" || fail "uncached resolve must find $tip:" "$out" "$err"
[[ ! -e "$other" ]] || fail "no cache dir may appear when unset"
# The tick's workflow ref turns it on under RUNNER_TEMP.
resolve RUNNER_TEMP="$TMP/rt" GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly-next-tick.yml@refs/heads/main"
[[ "$status" == 0 ]] && [[ -n "$(ls -A "$TMP/rt/cmux-tui-tree-probes" 2>/dev/null)" ]] \
  || fail "the tick's workflow ref must default the cache under RUNNER_TEMP (exit $status):" "$err"
resolve RUNNER_TEMP="$TMP/rt2" GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/main"
[[ ! -e "$TMP/rt2/cmux-tui-tree-probes" ]] || fail "other workflows must not cache"
echo "pin-cmux-tui resolve probe cache: ok"
