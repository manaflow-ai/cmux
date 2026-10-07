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
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
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
  [[ "$event" == pull_request ]] || publisher="$sha"
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
# workflow publishes a merge tree by itself (#18121, #18130). With
# CMUX_TUI_TREE_DISPATCH=1 (same-repository PRs only) the probe starts ONE
# cmux-tui-artifacts run on a cmux-tui-pin-<sha12> ref at the merge commit and
# defers: that run's publish starts the tree jobs (cmux_next_tree_notify.py).
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
expect "pull request, changed hash, dispatch off (fork)" pull_request failed "no cmux-tui artifacts run"
[[ "$(posts dispatches)" == 0 ]] || fail "(b) a fork PR (no CMUX_TUI_TREE_DISPATCH) must not dispatch"
export CMUX_TUI_TREE_DISPATCH=1
expect "pull request, changed hash" pull_request deferred
[[ "$(posts dispatches)" == 1 && "$(posts git/refs)" == 1 ]] || fail "(b) a changed hash needs one pin ref and one dispatch: $(cat "$TMP/posts.log")"
grep -q "cmux-tui-pin-${merge_sha:0:12}.*$merge_sha" "$TMP/posts.log" || fail "(b) the pin ref must point at the merge commit: $(cat "$TMP/posts.log")"
# The post-marker probe sees the queued run: still one dispatch.
expect "pull request, changed hash, second look" pull_request deferred
[[ "$(posts dispatches)" == 1 ]] || fail "(b) a second probe must not dispatch again: $(cat "$TMP/posts.log")"

# (c) The API refuses a ref at the merge commit: the PR head is pinned instead,
# but only when its tree key is the merge's (a PR whose base left cmux-tui alone).
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
export REFUSE_REF_SHA="$merge2_sha" CMUX_TUI_TREE_HEAD_SHA="$head2_sha"
expect "pull request, merge ref refused, head has the tree" pull_request deferred
grep -q "cmux-tui-pin-${head2_sha:0:12}.*$head2_sha" "$TMP/posts.log" || fail "(c) the PR head must be pinned: $(cat "$TMP/posts.log")"
[[ "$(posts dispatches)" == 1 ]] || fail "(c) one dispatch: $(cat "$TMP/posts.log")"
unset REFUSE_REF_SHA CMUX_TUI_TREE_HEAD_SHA CMUX_TUI_TREE_DISPATCH

printf 'pin-cmux-tui probe tests: ok\n'
