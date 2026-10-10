#!/usr/bin/env bash
# pin-cmux-tui.sh resolve-newest-published: the nightly takes the newest
# commit on its branch whose cmux-tui tree IS published, verified by the
# publishing commit's manifest sha256. It never waits for the tip's tree:
# under steady pushes the artifacts workflow supersedes the tip's queued run,
# so the tip's tree may never publish (nightly-next run 37464320457 failed
# after 45 min waiting for tree 23f87460a409). The search is bounded and a
# miss fails with a clear message. No network: a stub curl serves the CDN.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
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
path="\${url#https://files.cmux.com/cmux-tui/}"
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

# The tip and the next cmux-tui commit are unusable; the published tree wins at once.
started=$SECONDS
resolve
[[ "$status" == 0 ]] || fail "resolve-newest-published failed (exit $status):" "$out" "$err"
(( SECONDS - started < 20 )) || fail "the resolver waited $((SECONDS - started))s; it must not wait for the tip's tree"
grep -qx "commit=$published" <<<"$out" || fail "expected commit=$published (newest published tree), got:" "$out" "$err"
grep -qx "key=$(key "$published")" <<<"$out" || fail "expected the published tree's key, got:" "$out"
grep -qx "source_commit=$published" <<<"$out" || fail "expected source_commit=$published, got:" "$out"
grep -qx "tip_key=$(key "$tip")" <<<"$out" || fail "expected tip_key of the checkout, got:" "$out"
grep -Eqx "behind=[0-9]+" <<<"$out" && grep -Eqx "behind_hours=[0-9]+" <<<"$out" \
  || fail "expected behind= (commits) and behind_hours= lines, got:" "$out"
grep -q "manifest" <<<"$err" && grep -q "${mismatch:0:12}" <<<"$err" \
  || fail "the manifest sha256 mismatch of ${mismatch:0:12} must be reported:" "$err"

# The step summary records the tree and the commit.
summary="$TMP/summary.md"
resolve GITHUB_STEP_SUMMARY="$summary"
[[ "$status" == 0 ]] || fail "resolve with a step summary failed:" "$err"
grep -q "$(key "$published")" "$summary" && grep -q "$published" "$summary" \
  || fail "the step summary must name the tree and the commit:" "$(cat "$summary" 2>/dev/null)"

# The search is bounded: with a window of 2 commits nothing is published.
resolve CMUX_TUI_TREE_SEARCH_COMMITS=2
[[ "$status" != 0 ]] || fail "a bounded search with no published tree must fail, got:" "$out"
grep -q 'no published cmux-tui tree in the last 2 commits' <<<"$err" || fail "the miss needs a clear message:" "$err"

# A bad bound is a usage error.
resolve CMUX_TUI_TREE_SEARCH_COMMITS=x
[[ "$status" == 2 ]] || fail "CMUX_TUI_TREE_SEARCH_COMMITS=x must exit 2, got $status:" "$err"

# A shallow (depth 1) checkout deepens to find the published tree.
git_q clone --depth 1 "file://$src" "$TMP/shallow"
status=0
out=$(cd "$TMP/shallow" && env -u GITHUB_STEP_SUMMARY PATH="$TMP/bin:$PATH" bash scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published 2>"$TMP/err") || status=$?
[[ "$status" == 0 ]] && grep -qx "commit=$published" <<<"$out" || fail "a shallow checkout must deepen and resolve $published (exit $status):" "$out" "$(cat "$TMP/err")"
# Never ship a stale build: a newest published tree more than
# CMUX_TUI_TREE_MAX_AGE_HOURS (default 24) behind the tip fails the nightly.
echo app2 > "$src/App.swift"; git_q -C "$src" add -A
future=$(( $(git -C "$src" log -1 --format=%ct) + 30 * 3600 ))
GIT_COMMITTER_DATE="@$future +0000" git_q -C "$src" commit -m "app 30 h later"
resolve
[[ "$status" != 0 ]] || fail "a published tree 30 h behind the tip must fail the 24 h bound, got:" "$out"
grep -q 'h behind the tip' <<<"$err" && grep -q 'bound 24 h' <<<"$err" \
  || fail "the stale refusal needs a clear message:" "$err"
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48
[[ "$status" == 0 ]] && grep -qx "commit=$published" <<<"$out" && grep -qx "behind_hours=30" <<<"$out" \
  || fail "with a 48 h bound the 30 h old tree resolves with behind_hours=30 (exit $status):" "$out" "$err"
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=x
[[ "$status" == 2 ]] || fail "CMUX_TUI_TREE_MAX_AGE_HOURS=x must exit 2, got $status:" "$err"
# The workflow that builds a commit is the workflow AT that commit. The
# nightly runs nightly.yml from the tip but checks out the resolved commit, so
# a commit whose nightly.yml differs from the tip's cannot be built by it
# (nightly-next run 37568319518: the tip's workflow called
# scripts/upload-sentry-dsyms.sh, absent from the resolved 969eaa22).
# CMUX_TUI_TREE_SAME_PATHS skips such commits; a miss fails clearly.
mkdir -p "$src/.github/workflows"
echo "steps: new" > "$src/.github/workflows/nightly.yml"
git_q -C "$src" add -A; GIT_COMMITTER_DATE="@$future +0000" git_q -C "$src" commit -m "workflow change"
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48
[[ "$status" == 0 ]] && grep -qx "commit=$published" <<<"$out" \
  || fail "without CMUX_TUI_TREE_SAME_PATHS the old tree still resolves (exit $status):" "$out" "$err"
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48 CMUX_TUI_TREE_SAME_PATHS=.github/workflows/nightly.yml
[[ "$status" != 0 ]] || fail "a published tree whose nightly.yml differs from the tip must not resolve, got:" "$out"
grep -q '.github/workflows/nightly.yml differs from the tip' <<<"$err" \
  || fail "the workflow skew needs a clear message:" "$err"
# Once a commit with the tip's workflow has a published tree, it resolves.
publish "$(git -C "$src" rev-parse HEAD)" ""
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48 CMUX_TUI_TREE_SAME_PATHS=.github/workflows/nightly.yml
[[ "$status" == 0 ]] && grep -qx "source_commit=$(git -C "$src" rev-parse HEAD)" <<<"$out" \
  || fail "the tip with the same workflow and a published tree must resolve (exit $status):" "$out" "$err"

# Run the workflow's actual path policy against a repaired Chief lockfile.
# Nightly-next run 37724899486 selected a published revision that predated
# the lock repair on its tip, then failed the Chief's cargo build --locked.
nightly_same_paths=$(sed -n 's/^ *CMUX_TUI_TREE_SAME_PATHS: *//p' "$ROOT/.github/workflows/nightly.yml")
[[ -n "$nightly_same_paths" ]] || fail "nightly.yml must configure the resolver's same-path policy"
chief_lock=Native/OptChat/optchat-chief/Cargo.lock
mkdir -p "$src/$(dirname "$chief_lock")"
echo stale > "$src/$chief_lock"
git_q -C "$src" add -A; GIT_COMMITTER_DATE="@$future +0000" git_q -C "$src" commit -m "Chief before lock repair"
publish "$(git -C "$src" rev-parse HEAD)" ""
echo repaired > "$src/$chief_lock"
echo five > "$src/cmux-tui/a"
git_q -C "$src" add -A; GIT_COMMITTER_DATE="@$future +0000" git_q -C "$src" commit -m "repair Chief lock and update tui"
repaired=$(git -C "$src" rev-parse HEAD)
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48 "CMUX_TUI_TREE_SAME_PATHS=$nightly_same_paths"
[[ "$status" != 0 ]] || fail "nightly must not resolve a published revision with the stale Chief lockfile, got:" "$out"
grep -q "$chief_lock differs from the tip" <<<"$err" \
  || fail "the stale Chief lockfile refusal needs a clear message:" "$err"

# Once the repaired revision's tree publishes, the same policy accepts it.
publish "$repaired" ""
resolve CMUX_TUI_TREE_MAX_AGE_HOURS=48 "CMUX_TUI_TREE_SAME_PATHS=$nightly_same_paths"
[[ "$status" == 0 ]] && grep -qx "source_commit=$repaired" <<<"$out" \
  || fail "nightly must resolve the published revision with the repaired Chief lockfile (exit $status):" "$out" "$err"
: "$old"
echo "PASS: resolve-newest-published picks the newest verified published tree without waiting"
