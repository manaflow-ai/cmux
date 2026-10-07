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
    CMUX_TUI_TREE_PUBLISHER_SHA="$publisher" CMUX_TUI_TREE_PR_NUMBER=7 \
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

# A pull request whose merge changes cmux-tui on both sides has a merge tree that nothing publishes:
# GitHub runs pull_request_target workflows only from the default branch, so cmux-tui artifacts
# never builds a PR merge commit (#18121, #18130). The PR head's tree, published from a
# cmux-tui-pin-* push, is tested instead; with no published head tree the probe still fails.
git_q -C "$TMP/src" checkout -b pr "$base_sha"
echo head > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" commit -am head
head_sha=$(git -C "$TMP/src" rev-parse HEAD)
head_key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
git_q -C "$TMP/src" checkout main
echo base > "$TMP/src/cmux-tui/b"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m base-tui
git_q -C "$TMP/src" merge --no-ff -m merge pr
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
[[ "$key" != "$head_key" ]] || { echo "fixture: the merge has the head's tree key" >&2; exit 1; }
set_runs "$none"
export CMUX_TUI_TREE_HEAD_SHA="$head_sha"
expect "pull request, merge tree unpublished, head unpublished" pull_request failed "no cmux-tui artifacts run"
mkdir -p "$TMP/cdn/cmux-tui/tree/$head_key"
printf '%064d  cmux-tui-aarch64-apple-darwin\n' 0 > "$TMP/cdn/cmux-tui/tree/$head_key/cmux-tui-aarch64-apple-darwin.sha256"
merge_key="$key"; key="$head_key"
expect "pull request, merge tree unpublished, head published" pull_request ready "$merge_key"
grep -qF "$head_sha" <<<"$reason" || fail "the reason names the PR head: $reason"
# fetch takes the probe's key only when it is exactly the PR head's own tree key.
echo binary > "$TMP/cdn/cmux-tui/tree/$head_key/cmux-tui-aarch64-apple-darwin"
sha256sum "$TMP/cdn/cmux-tui/tree/$head_key/cmux-tui-aarch64-apple-darwin" | awk '{print $1 "  cmux-tui-aarch64-apple-darwin"}' \
  > "$TMP/cdn/cmux-tui/tree/$head_key/cmux-tui-aarch64-apple-darwin.sha256"
fetch_with() { # <CMUX_TUI_TREE_KEY> -> out, status
  status=0
  out=$(cd "$TMP/src" && env -u CI_JOB_DIR PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request \
    GITHUB_REPOSITORY=o/r GITHUB_API_URL="file://$TMP/api" GH_TOKEN=test-token CMUX_TUI_TREE_KEY="$1" \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=1 CMUX_TUI_TREE_POLL_SECONDS=1 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || status=$?
}
fetch_with "$head_key"
grep -qF "using the PR head's tree $head_key" <<<"$out" || fail "fetch did not take the PR head's tree"
[[ -f "$TMP/src/cmux-tui/target/hosted/tree/$head_key/cmux-tui" ]] || fail "fetch did not place the head tree's binary"
fetch_with "$newer"
! grep -qF "using the PR head's tree" <<<"$out" || fail "fetch took a key that is not the PR head's"
unset CMUX_TUI_TREE_HEAD_SHA

printf 'pin-cmux-tui probe tests: ok\n'
