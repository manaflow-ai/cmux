#!/usr/bin/env bash
# pin-cmux-tui.sh resolve-newest-published in nightly.yml: when no commit in the
# window resolves, it waits once, bounded, for the publisher of the tip's own
# tree, then resolves again. Nightly-next run 40445128409 failed with "tree
# bf6faf9c692f (5d81874b330a): not published" while same-key run 40444370171
# was still building that tree, and every older commit carried a different
# nightly.yml. It never waits when a commit resolves, never outside nightly.yml,
# fails at once when nothing publishes the tree (it holds actions: read, so it
# starts no publisher), and fails on a publisher that ends without publishing
# or at the bound. No network: a stub curl serves the CDN and the Actions API;
# waits run on a virtual clock.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
source "$ROOT/scripts/cmux-next/tests/lib/fake-clock.sh"
fake_clock_install "$TMP/clock"
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
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
git_q -C "$src" add -A; git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
echo two > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui two"
owner=$(git -C "$src" rev-parse HEAD)
# The tip shares owner's tree (an app-only commit), as 5d81874b shared a57c9faa's.
echo app > "$src/App.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "app only"
tip=$(git -C "$src" rev-parse HEAD)
key=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$tip")
[[ "$key" == "$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$owner")" ]] \
  || { echo "fixture: the tip and owner must share a tree" >&2; exit 1; }

cdn="$TMP/cdn" api="$TMP/api"
mkdir -p "$api"
cat > "$TMP/publish" <<EOF
#!/usr/bin/env bash
# publish <commit>: the tree, its source.json and the commit's manifest on the CDN.
mkdir -p "$cdn/tree/$key" "$cdn/\$1"
echo "build of \$1" > "$cdn/tree/$key/$bin"
s=\$(shasum -a 256 "$cdn/tree/$key/$bin" | awk '{print \$1}')
echo "\$s" > "$cdn/tree/$key/$bin.sha256"
printf '{"key": "%s", "commit": "%s"}\n' "$key" "\$1" > "$cdn/tree/$key/source.json"
printf '{"commit": "%s", "binaries": {"%s": "%s"}}\n' "\$1" "$bin" "\$s" > "$cdn/\$1/manifest.json"
EOF
chmod +x "$TMP/publish"
# runs <sha> <status> [conclusion]: the cmux-tui artifacts runs of <sha> (empty: none).
runs() {
  if [[ -z "$2" ]]; then echo '{"workflow_runs": []}' > "$api/runs-$1.json"; return; fi
  local conclusion=null
  [[ -z "${3:-}" ]] || conclusion="\"$3\""
  printf '{"workflow_runs": [{"id": 1, "head_sha": "%s", "status": "%s", "conclusion": %s, "html_url": "u1"}]}\n' \
    "$1" "$2" "$conclusion" > "$api/runs-$1.json"
}
# all <sha> <status>: the workflow's recent runs (active_publisher_for_key reads them).
all() { printf '{"workflow_runs": [{"id": 2, "head_sha": "%s", "status": "%s"}]}\n' "$1" "$2" > "$api/all.json"; }
reset() { rm -rf "$cdn" "$api"; mkdir -p "$cdn" "$api"; echo '{"workflow_runs": []}' > "$api/all.json"; : > "$FAKE_CLOCK_EVENTS"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|-H|-X|-d|--proto|--retry|--retry-delay|--connect-timeout|--max-time|-w) [[ "\$1" == -o ]] && out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  https://api.github.com/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs\?head_sha=*)
    s="\${url##*head_sha=}"; s="\${s%%&*}"
    cat "$api/runs-\$s.json" 2>/dev/null || echo '{"workflow_runs": []}'; exit 0 ;;
  https://api.github.com/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs\?per_page=*)
    cat "$api/all.json"; exit 0 ;;
  https://api.github.com/*) exit 22 ;;
esac
# A sha256 read without a cache-busting query gets the edge's cached 404 (it missed once).
[[ "\$url" == *.sha256 ]] && exit 22
path="\${url#https://files.cmux.com/cmux-tui/}"; path="\${path%%\?*}"
[[ "\$path" != "\$url" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
chmod +x "$TMP/bin/curl"

NIGHTLY_REF=o/r/.github/workflows/nightly.yml@refs/heads/nightly-next
# resolve [env...] -> out (stdout), err, status, took (virtual seconds)
resolve() {
  local started; started=$(date +%s); status=0
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_TIP_WAIT_SECONDS -u GITHUB_WORKFLOW_REF \
    PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REPOSITORY=o/r \
    GITHUB_API_URL=https://api.github.com GH_TOKEN=test CMUX_TUI_TREE_SEARCH_COMMITS=1 \
    CMUX_TUI_TREE_POLL_SECONDS=30 CMUX_TUI_TREE_RUN_CHECK_SECONDS=60 "$@" \
    bash scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published 2>"$TMP/err") || status=$?
  err=$(cat "$TMP/err"); took=$(( $(date +%s) - started ))
}
fail() { printf '%s (exit %s, %ss)\n' "$1" "$status" "$took" >&2; printf '%s\n' "$out" "$(tail -n 15 <<<"$err")" >&2; exit 1; }

# 1. The tip's run is in progress, then publishes: the nightly waits and builds the tip.
reset; runs "$tip" in_progress
fake_clock_at 300 "'$TMP/publish' '$tip'; printf '{\"workflow_runs\": [{\"id\": 1, \"status\": \"completed\", \"conclusion\": \"success\", \"html_url\": \"u1\"}]}' > '$api/runs-$tip.json'"
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 0 ]] || fail "in progress, then published: the resolver must wait and resolve the tip"
grep -qx "source_commit=$tip" <<<"$out" && grep -qx "commit=$tip" <<<"$out" || fail "in progress: expected the tip"
grep -q "waiting up to 3000s for the publisher of the tip" <<<"$err" || fail "in progress: the wait needs a log line with its bound"
(( took >= 300 && took < 600 )) || fail "in progress: expected to stop waiting once the tree published"

# 2. The tip's own run deferred (ended success) to a same-key owner that is still building
#    (the 40445128409 case): it waits for the owner, then resolves the tip.
reset; runs "$tip" completed success; all "$owner" in_progress
fake_clock_at 600 "'$TMP/publish' '$owner'"
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 0 ]] && grep -qx "source_commit=$tip" <<<"$out" && grep -qx "commit=$owner" <<<"$out" \
  || fail "same-key owner: the resolver must wait for the owner and resolve the tip with the owner's manifest"

# 2b. The recent runs list cannot be read (rate limit, network): that is not "no publisher".
#     The tip's own run deferred, so only that list could show the owner: wait, bounded, and
#     resolve once the owner publishes, instead of failing fast.
reset; runs "$tip" completed success; echo 'API rate limit exceeded' > "$api/all.json"
fake_clock_at 300 "'$TMP/publish' '$owner'"
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 0 ]] && grep -qx "source_commit=$tip" <<<"$out" || fail "unreadable runs list: must wait, not fail fast"
grep -q "a same-tree run is unknown" <<<"$err" || fail "unreadable runs list: say the run is unknown"
(( took >= 300 && took < 600 )) || fail "unreadable runs list: expected to stop waiting once the tree published"
# A structurally wrong body (no list of runs) is unknown too, not an empty list.
for body in '{"workflow_runs": null}' '{"workflow_runs": [1]}' '{}'; do
  reset; runs "$tip" completed success; echo "$body" > "$api/all.json"
  fake_clock_at 300 "'$TMP/publish' '$owner'"
  resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
  [[ "$status" == 0 ]] && grep -q "a same-tree run is unknown" <<<"$err" || fail "malformed runs list $body: must be unknown and wait"
done

# 3. No run exists: it fails at once with what to dispatch (no actions: write, no dispatch).
reset; runs "$tip" ""
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 1 ]] || fail "no publisher: must fail"
(( took == 0 )) || fail "no publisher: must not wait"
grep -q "No cmux-tui artifacts run exists for $tip" <<<"$err" \
  && grep -q "gh workflow run cmux-tui-artifacts.yml --repo o/r --ref feat-cmux-next" <<<"$err" \
  || fail "no publisher: the failure must say to dispatch the artifacts workflow"

# 4a. The publisher already failed: fail at once with its run.
reset; runs "$tip" completed failure
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 1 ]] && (( took == 0 )) || fail "failed publisher: must fail at once"
grep -q "ended without publishing it: failure: u1" <<<"$err" || fail "failed publisher: name the failed run"

# 4b. The publisher fails while the nightly waits: fail on its two ended checks, not at the bound.
reset; runs "$tip" in_progress
fake_clock_at 200 "printf '{\"workflow_runs\": [{\"id\": 1, \"status\": \"completed\", \"conclusion\": \"failure\", \"html_url\": \"u1\"}]}' > '$api/runs-$tip.json'"
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 1 ]] || fail "publisher failing mid-wait: must fail"
grep -q "no cmux-tui artifacts run will publish tree $key" <<<"$err" && grep -q "failure: u1" <<<"$err" \
  || fail "publisher failing mid-wait: name the failure"
(( took >= 200 && took < 600 )) || fail "publisher failing mid-wait: must stop soon after the failure"

# 5. The bound: a publisher that never finishes fails at CMUX_TUI_TREE_TIP_WAIT_SECONDS.
reset; runs "$tip" in_progress
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF" CMUX_TUI_TREE_TIP_WAIT_SECONDS=600
[[ "$status" == 1 ]] || fail "timeout: must fail"
grep -q "tree $key is not published after 10 min" <<<"$err" || fail "timeout: say the bound was hit"
(( took >= 600 && took < 700 )) || fail "timeout: must stop at the bound"

# 6. Outside nightly.yml (request-nightly-next.sh, the media workflow) a miss never waits.
reset; runs "$tip" in_progress
resolve
[[ "$status" == 1 ]] && (( took == 0 )) || fail "outside nightly.yml: a miss must fail at once"
grep -q "no published cmux-tui tree in the last 1 commits" <<<"$err" || fail "outside nightly.yml: the old miss message"
grep -q "waiting up to" <<<"$err" && fail "outside nightly.yml: must not wait"

# 7. A hit never waits, in nightly.yml too.
reset; "$TMP/publish" "$owner"; runs "$tip" in_progress
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF"
[[ "$status" == 0 ]] && (( took == 0 )) && grep -qx "source_commit=$tip" <<<"$out" || fail "a published tip must resolve at once"

# A bad bound is a usage error.
resolve GITHUB_WORKFLOW_REF="$NIGHTLY_REF" CMUX_TUI_TREE_TIP_WAIT_SECONDS=x
[[ "$status" == 2 ]] || fail "CMUX_TUI_TREE_TIP_WAIT_SECONDS=x must exit 2"
echo "PASS: resolve-newest-published in nightly.yml waits once, bounded, for the tip's publisher"
