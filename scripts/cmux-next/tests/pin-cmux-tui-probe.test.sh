#!/usr/bin/env bash
# pin-cmux-tui.sh probe: the cmux-next same-tree check looks once (plus one
# short re-check) and never waits for a publication. It writes tree_state:
#   ready       the tree is published; the tree jobs run in this run
#   deferred    an artifacts run that can publish it is active; its publish
#               starts the tree jobs (scripts/ci/cmux_next_tree_notify.py)
#   superseded  a newer branch head replaced this push; nothing to test
#   failed      nothing will publish it; the run reports the reason in red
# No network: a curl shim serves the CDN from files, the GitHub API is file://.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Waits run on a virtual clock: `took` is the time the script would have waited, exactly.
source "$ROOT/scripts/cmux-next/tests/lib/fake-clock.sh"
fake_clock_install "$TMP/clock"
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo one > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m one
base_sha=$(git -C "$TMP/src" rev-parse HEAD)
# A merge whose first parent is the base and that leaves cmux-tui alone has the
# base's tree key (a pull request that does not touch cmux-tui).
echo app > "$TMP/src/app.swift"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m app
sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
[[ "$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key --rev HEAD^1)" == "$key" ]] || {
  echo "fixture: the app commit changed the tree key" >&2; exit 1; }

# The CDN: https://cdn.test/cmux-tui/<path> serves $TMP/cdn/<path>, else 404.
mkdir -p "$TMP/bin" "$TMP/cdn"
real_curl=$(command -v curl)
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""; args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i+1]}" ;;
    https://cdn.test/*) url="\${args[i]}" ;;
  esac
done
method=GET; body=""; api=""
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -X) method="\${args[i+1]}" ;;
    -d) body="\${args[i+1]}" ;;
    file://*) api="\${args[i]}" ;;
  esac
done
if [[ "\$method" == POST ]]; then
  echo "POST \${api##*/repos/o/r/} \$body" >> "$TMP/posts.log"
  # REFUSE_WRITES: the pull request token's 403 on every write.
  [[ -n "\${REFUSE_WRITES:-}" ]] && exit 22
  case "\$api" in
    */git/refs)
      # REFUSE_REF_SHA: the API refuses a ref at that commit (422).
      [[ -n "\${REFUSE_REF_SHA:-}" && "\$body" == *"\$REFUSE_REF_SHA"* ]] && exit 22
      exit 0 ;;
    */dispatches)
      # The dispatched run appears at once for the pinned commit.
      pinned=\$(grep 'git/refs' "$TMP/posts.log" | tail -n 1 | sed -E 's/.*"sha":"([0-9a-f]{40})".*/\1/')
      printf '{"total_count":1,"workflow_runs":[{"id":9,"status":"queued","conclusion":null,"html_url":"u9","head_sha":"%s","pull_requests":[]}]}\n' "\$pinned" \
        > "$TMP/api/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs"
      exit 0 ;;
  esac
  exit 22
fi
# A head_sha= run query lists only that commit's runs (a run without head_sha
# matches every query, as the older fixtures expect).
if [[ -z "\$url" && "\$api" == *"head_sha="* ]]; then
  want="\${api##*head_sha=}"; want="\${want%%&*}"
  "$real_curl" "\$@" | python3 -c '
import json, sys
data = json.load(sys.stdin)
data["workflow_runs"] = [r for r in data.get("workflow_runs", []) if r.get("head_sha", sys.argv[1]) == sys.argv[1]]
print(json.dumps(data))' "\$want"
  exit "\${PIPESTATUS[0]}"
fi
if [[ -z "\$url" ]]; then exec "$real_curl" "\$@"; fi
path="$TMP/cdn/\${url#https://cdn.test/}"; path="\${path%%\\?*}"
[[ -f "\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "\$path" "\$out"; else cat "\$path"; fi
SHIM
chmod +x "$TMP/bin/curl"

runs_dir="$TMP/api/repos/o/r/actions/workflows/cmux-tui-artifacts.yml"
head_dir="$TMP/api/repos/o/r/git/ref/heads"
mkdir -p "$runs_dir" "$head_dir"
set_runs() { printf '%s\n' "$1" > "$runs_dir/runs"; }
set_head() { printf '{"object":{"sha":"%s"}}\n' "$1" > "$head_dir/feat-cmux-next"; }
newer=$(printf 'f%.0s' {1..40})

# probe <event> -> sets out, status, took, state (tree_state), reason
probe() {
  local event="$1" publisher=""
  if [[ "${CMUX_TUI_DEV_DAILY:-}" == 1 ]]; then
    publisher="$DEV_DAILY_PUBLISHER_SHA"
  elif [[ "$event" != pull_request ]]; then
    publisher="$sha"
  fi
  : > "$TMP/gh-output"
  local started; started=$(date +%s)
  status=0
  out=$(cd "$TMP/src" && env -u CI_JOB_DIR PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true GITHUB_EVENT_NAME="$event" \
    GITHUB_SHA="$sha" GITHUB_REF=refs/heads/feat-cmux-next GITHUB_OUTPUT="$TMP/gh-output" \
    GITHUB_REPOSITORY=o/r GITHUB_API_URL="file://$TMP/api" GH_TOKEN=test-token \
    CMUX_TUI_TREE_PUBLISHER_SHA="$publisher" CMUX_TUI_TREE_DISPATCH_SETTLE_SECONDS=0 \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_RECHECK_SECONDS=1 \
    bash scripts/cmux-next/pin-cmux-tui.sh probe 2>&1) || status=$?
  took=$(( $(date +%s) - started ))
  state=$(awk -F= '$1 == "tree_state" { print $2 }' "$TMP/gh-output")
  reason=$(awk -F= '$1 == "tree_reason" { sub(/^[^=]*=/, ""); print }' "$TMP/gh-output")
}
fail() { printf '%s (exit %s, %ss, state %s), output:\n%s\n' "$1" "$status" "$took" "${state:-none}" "$(tail -n 12 <<<"$out")" >&2; exit 1; }
expect() { # <case> <event> <state> [reason text]
  probe "$2"
  [[ "$status" == 0 ]] || fail "$1: probe exited non-zero"
  (( took < 10 )) || fail "$1: probe waited"
  [[ "$state" == "$3" ]] || fail "$1: expected tree_state=$3"
  grep -qxF "tree_key=$key" "$TMP/gh-output" || fail "$1: no tree_key output"
  if [[ -n "${4:-}" ]]; then grep -qF "$4" <<<"$reason" || fail "$1: reason lacks '$4': $reason"; fi
}

active='{"total_count":1,"workflow_runs":[{"id":1,"status":"in_progress","conclusion":null,"html_url":"u1","pull_requests":[{"number":7}]}]}'
cancelled='{"total_count":1,"workflow_runs":[{"id":2,"status":"completed","conclusion":"cancelled","html_url":"u2","pull_requests":[]}]}'
failed_run='{"total_count":1,"workflow_runs":[{"id":3,"status":"completed","conclusion":"failure","html_url":"u3","pull_requests":[]}]}'
none='{"total_count":0,"workflow_runs":[]}'

set_head "$sha"
set_runs "$active"
expect "push, publisher active" push deferred
set_head "$newer"; set_runs "$cancelled"
expect "push, superseded" push superseded "$newer"
set_head "$sha"; set_runs "$failed_run"
expect "push, publish failed" push failed "failure: u3"
set_runs "$none"
expect "push, no artifacts run" push failed "no cmux-tui artifacts run"
rm -f "$runs_dir/runs"
expect "push, unreadable API" push failed "could not read"

# A pull request whose merge keeps the base's cmux-tui waits for the base push's publisher.
set_runs "$active"
expect "pull request, base publisher active" pull_request deferred
set_runs "$failed_run"
expect "pull request, base publish failed" pull_request failed "$base_sha"

# Published: ready, from the v2 key.
mkdir -p "$TMP/cdn/cmux-tui/tree/$key"
printf '%064d  cmux-tui-aarch64-apple-darwin\n' 0 > "$TMP/cdn/cmux-tui/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"
set_runs "$failed_run"
expect "push, published" push ready
expect "pull request, published" pull_request ready

# A pull request job resolves its artifact by the SOURCE tree key of the merge
# tree. GitHub runs pull_request_target only from the default branch, so no
# workflow publishes a merge tree by itself (#18121, #18130). A missing merge
# tree is reported for trusted fleet publication; no helper ref is created.
posts() { grep -c "$1" "$TMP/posts.log" 2>/dev/null || true; }
: > "$TMP/posts.log"

# (a) The merge keeps a published cmux-tui hash: the artifact is reused, 0 dispatches.
export CMUX_TUI_TREE_DISPATCH=1
expect "pull request, unchanged hash" pull_request ready
[[ "$(posts dispatches)" == 0 && "$(posts git/refs)" == 0 ]] || fail "(a) a published merge hash must start no publisher: $(cat "$TMP/posts.log")"

# (b) The merge changes cmux-tui on both sides: its hash is published nowhere.
git_q -C "$TMP/src" checkout -b pr "$base_sha"
echo head > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" commit -am head
head_sha=$(git -C "$TMP/src" rev-parse HEAD)
git_q -C "$TMP/src" checkout main
echo base > "$TMP/src/cmux-tui/b"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m base-tui
git_q -C "$TMP/src" merge --no-ff -m merge pr
merge_sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
[[ "$key" != "$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key --rev "$head_sha")" ]] || {
  echo "fixture: the merge has the head's tree key" >&2; exit 1; }
set_runs "$none"
unset CMUX_TUI_TREE_DISPATCH
# A fork PR: main's merge-tree publisher never starts, so path routing looks once (wait 0).
export CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0
expect "pull request, changed hash, dispatch off (fork)" pull_request failed "no cmux-tui artifacts run"
[[ "$(posts dispatches)" == 0 ]] || fail "(b) a fork PR (no CMUX_TUI_TREE_DISPATCH) must not dispatch"
unset CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS
export CMUX_TUI_TREE_DISPATCH=1
export CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0
expect "pull request, changed hash" pull_request failed
[[ "$(posts dispatches)" == 0 && "$(posts git/refs)" == 0 ]] || fail "(b) a changed hash must not create a ref or dispatch: $(cat "$TMP/posts.log")"
# A second probe remains a read-only failure until a trusted publisher appears.
expect "pull request, changed hash, second look" pull_request failed
[[ "$(posts dispatches)" == 0 && "$(posts git/refs)" == 0 ]] || fail "(b) a second probe must not dispatch: $(cat "$TMP/posts.log")"

# (c) A merge whose tree is not published is still reported without creating a
# ref at either the merge commit or the PR head.
: > "$TMP/posts.log"
git_q -C "$TMP/src" checkout -b pr2 "$base_sha"
echo head2 > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" commit -am head2
head2_sha=$(git -C "$TMP/src" rev-parse HEAD)
git_q -C "$TMP/src" checkout -b merge2 "$base_sha"
git_q -C "$TMP/src" merge --no-ff -m merge2 pr2
merge2_sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
set_runs "$none"
export REFUSE_REF_SHA="$merge2_sha" CMUX_TUI_TREE_HEAD_SHA="$head2_sha" CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0
expect "pull request, merge ref refused, head has the tree" pull_request failed
[[ "$(posts dispatches)" == 0 && "$(posts git/refs)" == 0 ]] || fail "(c) the PR head must not be published through a helper ref: $(cat "$TMP/posts.log")"
unset REFUSE_REF_SHA CMUX_TUI_TREE_HEAD_SHA CMUX_TUI_TREE_DISPATCH CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS

# (d) The pull request's own token may write nothing (HTTP 403 on the pin ref
# and the dispatch): main's cmux-next-pr-merge-tree.yml (pull_request_target)
# starts the publish instead, a moment after this run starts. The probe waits a
# bounded time for that run and defers to it, rather than failing same-tree.
: > "$TMP/posts.log"
set_runs "$none"
export CMUX_TUI_TREE_DISPATCH=1 REFUSE_WRITES=1 CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=8 CMUX_TUI_TREE_PUBLISHER_POLL_SECONDS=1
fake_clock_at 2 "printf '%s\\n' '$active' > '$runs_dir/runs'"
probe pull_request
[[ "$status" == 0 && "$state" == deferred ]] || fail "(d) a publish started from main must be waited for"
grep -qF "active cmux-tui artifacts run" <<<"$reason" || fail "(d) reason: $reason"
# No publish appears: the bounded wait ends and the check fails as before.
set_runs "$none"
probe pull_request
[[ "$state" == failed ]] || fail "(d) with no publisher the probe must still fail"
(( took < 15 )) || fail "(d) the wait must be bounded"
unset REFUSE_WRITES CMUX_TUI_TREE_DISPATCH CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS CMUX_TUI_TREE_PUBLISHER_POLL_SECONDS

# (e) Path routing is read-only since e93faa5f1fb0 (CMUX_TUI_TREE_DISPATCH is
# empty), so a same-repository PR with its own merge tree never reaches the
# dispatch path. Main's cmux-next-pr-merge-tree.yml has already pinned the merge
# commit and its cmux-tui artifacts run is active: the probe must look for that
# run (reads only) and defer, not fail with "no cmux-tui artifacts run can
# publish tree" (PR #22580, run 39491343806, 2026-10-20).
: > "$TMP/posts.log"
set_runs "$active"
expect "pull request, own merge tree, read-only probe, main's publisher active" pull_request deferred "active cmux-tui artifacts run"
[[ ! -s "$TMP/posts.log" ]] || fail "(e) the read-only probe must not write: $(cat "$TMP/posts.log")"
# The publisher appears during the bounded wait.
set_runs "$none"
export CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=8 CMUX_TUI_TREE_PUBLISHER_POLL_SECONDS=1
fake_clock_at 2 "printf '%s\\n' '$active' > '$runs_dir/runs'"
probe pull_request
[[ "$status" == 0 && "$state" == deferred ]] || fail "(e) a publish started from main during the wait must be deferred to"
# Nothing starts: the bounded wait ends and the check still fails, without writing.
set_runs "$none"
probe pull_request
[[ "$state" == failed ]] || fail "(e) with no publisher the read-only probe must still fail"
(( took < 15 )) || fail "(e) the wait must be bounded"
[[ ! -s "$TMP/posts.log" ]] || fail "(e) the read-only probe must not write: $(cat "$TMP/posts.log")"
unset CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS CMUX_TUI_TREE_PUBLISHER_POLL_SECONDS


# (d) A pull request that changes no cmux-tui or ghostty-next path is not
# blocked by a merge tree nothing publishes (#16614, #17551, #18605): the base
# tip moved to a new tree whose artifacts run was cancelled. With
# CMUX_TUI_TREE_BASE_FALLBACK=1 (path routing sets it for such a PR) the probe
# reuses the newest published tree in the merge's history (tree_fetch_key=),
# and the tree jobs fetch it through CMUX_TUI_TREE_KEY. Without a published
# tree it skips the tree jobs instead of failing. A PR that changes cmux-tui
# keeps the hard check (cases a-c: the fallback is off).
published_key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key --rev "$sha")
[[ -d "$TMP/cdn/cmux-tui/tree/$published_key" ]] || { echo "fixture: the app commit's tree is not published" >&2; exit 1; }
printf '{"commit":"%s"}\n' "$sha" > "$TMP/cdn/cmux-tui/tree/$published_key/source.json"
mkdir -p "$TMP/cdn/cmux-tui/$sha"
printf '{"binaries":{"cmux-tui-aarch64-apple-darwin":"%064d"}}\n' 0 > "$TMP/cdn/cmux-tui/$sha/manifest.json"
git_q -C "$TMP/src" checkout main
echo moved > "$TMP/src/cmux-tui/c"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m base-moved
git_q -C "$TMP/src" checkout -b swift-only
echo swift > "$TMP/src/app2.swift"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m swift-only
git_q -C "$TMP/src" checkout main
git_q -C "$TMP/src" merge --no-ff -m merge-swift-only swift-only
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
[[ "$key" != "$published_key" ]] || { echo "fixture: the moved base still has the published tree" >&2; exit 1; }
set_runs "$cancelled"
expect "pull request, no cmux-tui change, fallback off" pull_request failed "cancelled"
export CMUX_TUI_TREE_BASE_FALLBACK=1
expect "pull request, no cmux-tui change, base tree reused" pull_request ready "changes no cmux-tui"
grep -qxF "tree_fetch_key=$published_key" "$TMP/gh-output" || fail "(d) the tree jobs must fetch the newest published tree $published_key: $(cat "$TMP/gh-output")"
fetched=$(cd "$TMP/src" && CMUX_TUI_TREE_KEY="$published_key" bash scripts/cmux-next/pin-cmux-tui.sh path)
[[ "$fetched" == *"/$published_key/"*cmux-tui ]] || fail "(d) CMUX_TUI_TREE_KEY must select the fetched tree: $fetched"
mv "$TMP/cdn/cmux-tui/tree/$published_key" "$TMP/unpublished"
# This probe searches the recent history for a published tree, keying each commit's tree:
# compute, which the virtual clock does not count, so the usual bound holds.
expect "pull request, no cmux-tui change, nothing published" pull_request skipped "changes no cmux-tui"
mv "$TMP/unpublished" "$TMP/cdn/cmux-tui/tree/$published_key"
unset CMUX_TUI_TREE_BASE_FALLBACK

# A scheduled DEV snapshot owns its exact SHA after the source branch moves.
# Since e93faa5f1fb0 path routing is read-only (CMUX_TUI_TREE_DISPATCH=""), so
# the probe never writes a pin ref or a dispatch. It still looks once, read-only,
# for an artifacts run that publishes the tree: a cold tree with none reads
# failed, one whose push run (or the same-key run that push handed the build
# to) is running defers to it so dev-daily-tree-wait waits, and a published
# tree reads ready. DEV run 39499536927 (2026-10-20) failed while push run
# 39499455843 for its SHA and same-key owner run 39498123849 were running.
sha=$(git -C "$TMP/src" rev-parse HEAD)
set_head "$newer"
set_runs "$none"
: > "$TMP/posts.log"
# Use each real workflow probe's environment, not a hand-wired dispatch flag:
# a publisher SHA bypasses dispatch even when CMUX_TUI_TREE_DISPATCH is set.
dev_probe_environment() {
  python3 - "$ROOT/.github/workflows/cmux-next.yml" "$1" "$sha" <<'PYENV'
import json, shlex, subprocess, sys, yaml
workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
step = next(step for step in workflow["jobs"]["path_route"]["steps"] if step.get("id") == sys.argv[2])
context = {"github": {"event_name": "workflow_dispatch", "sha": sys.argv[3],
                       "ref": "refs/heads/feat-cmux-next", "repository": "o/r"},
           "inputs": {"dev_daily": True}}
for name in ("CMUX_TUI_TREE_PUBLISHER_SHA", "CMUX_TUI_TREE_DISPATCH"):
    expression = step["env"][name].removeprefix("${{").removesuffix("}}").strip()
    script = "const {github, inputs} = JSON.parse(process.argv[1]); process.stdout.write(String(eval(process.argv[2])));"
    value = subprocess.check_output(["node", "-e", script, json.dumps(context), expression], text=True)
    target = "DEV_DAILY_PUBLISHER_SHA" if name == "CMUX_TUI_TREE_PUBLISHER_SHA" else name
    print("export " + target + "=" + shlex.quote(value))
PYENV
}
export CMUX_TUI_DEV_DAILY=1
eval "$(dev_probe_environment tree)"
expect "scheduled dev, cold exact tree" workflow_dispatch failed "no cmux-tui artifacts run can publish tree $key"
[[ ! -s "$TMP/posts.log" ]] || fail "dev snapshot probe must not write (pin ref or dispatch): $(cat "$TMP/posts.log")"
eval "$(dev_probe_environment tree-final)"
expect "scheduled dev, second probe" workflow_dispatch failed "no cmux-tui artifacts run can publish tree $key"
[[ ! -s "$TMP/posts.log" ]] || fail "dev second probe must not write: $(cat "$TMP/posts.log")"
# The push's artifacts run for the exact SHA is still running: defer, one look
# (no wait), no write.
set_runs "{\"total_count\":1,\"workflow_runs\":[{\"id\":5,\"status\":\"in_progress\",\"conclusion\":null,\"html_url\":\"u5\",\"head_sha\":\"$sha\",\"pull_requests\":[]}]}"
eval "$(dev_probe_environment tree)"
expect "scheduled dev, cold tree, push publisher running" workflow_dispatch deferred "$sha"
(( took == 0 )) || fail "scheduled dev: the lookup must not wait (${took}s)"
[[ ! -s "$TMP/posts.log" ]] || fail "dev probe with a running publisher must not write: $(cat "$TMP/posts.log")"
eval "$(dev_probe_environment tree-final)"
expect "scheduled dev, second probe, push publisher running" workflow_dispatch deferred "$sha"
[[ ! -s "$TMP/posts.log" ]] || fail "dev second probe with a running publisher must not write: $(cat "$TMP/posts.log")"
# A same-tree run of another commit is the active owner (the push's own run
# handed the build to it): the probe defers to that commit.
owner_sha=$(git -c user.name=t -c user.email=t@example.com -C "$TMP/src" commit-tree "$sha^{tree}" -p "$sha" -m "same tree")
set_runs "{\"total_count\":1,\"workflow_runs\":[{\"id\":6,\"status\":\"in_progress\",\"conclusion\":null,\"html_url\":\"u6\",\"head_sha\":\"$owner_sha\",\"pull_requests\":[]}]}"
eval "$(dev_probe_environment tree)"
expect "scheduled dev, cold tree, same-key owner running" workflow_dispatch deferred "$owner_sha"
[[ ! -s "$TMP/posts.log" ]] || fail "dev probe with a same-key owner must not write: $(cat "$TMP/posts.log")"
set_runs "$none"
mkdir -p "$TMP/cdn/cmux-tui/tree/$key"
printf '%064d  cmux-tui-aarch64-apple-darwin\n' 0 > "$TMP/cdn/cmux-tui/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"
expect "scheduled dev, published by a trusted publisher" workflow_dispatch ready
[[ ! -s "$TMP/posts.log" ]] || fail "dev published probe must not write: $(cat "$TMP/posts.log")"

printf 'pin-cmux-tui probe tests: ok\n'
