#!/usr/bin/env bash
# pin-cmux-tui.sh fetch on an `nx-remote --ref` tree: the host mirror fetched
# the job's commit by SHA, so its remote-tracking refs are hours behind. A
# pushed commit (the feat-cmux-next tip) must still fetch its same-tree
# cmux-tui; only a commit that is on no branch of origin is refused.
# No network: origin is a local bare repo, and the CDN, the GitHub API and the
# public git fallback are unreachable, so a fetch that gets past the refusal
# stops at "is not published" and never reads the runner's own remotes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# origin: a repo whose feat-cmux-next tip changes cmux-tui.
git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
mkdir -p "$TMP/src/scripts/ci"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo one > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m one
# The ghostty gitlink tree_key needs (no submodule checkout: commit paths, never -a).
git_q -C "$TMP/src" update-index --add --cacheinfo 160000,"$(git -C "$TMP/src" rev-parse HEAD)",ghostty
git_q -C "$TMP/src" commit -m gitlink
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"

# The host mirror: a full clone, then origin moves on.
git_q clone "$TMP/origin.git" "$TMP/mirror"
echo two > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add cmux-tui/a
git_q -C "$TMP/src" commit -m "change cmux-tui"
git_q -C "$TMP/src" push "$TMP/origin.git" feat-cmux-next
tip=$(git -C "$TMP/src" rev-parse HEAD)
# What nx-remote --ref does: fetch the SHA alone (no remote-tracking update) and check it out.
git_q -C "$TMP/mirror" fetch origin "$tip"
git_q -C "$TMP/mirror" worktree add --detach "$TMP/job" "$tip"
[[ "$(git -C "$TMP/mirror" rev-parse origin/feat-cmux-next)" != "$tip" ]] || { echo "setup: mirror refs are not stale" >&2; exit 1; }

offline=(env -u GITHUB_ACTIONS -u CI_JOB_DIR -u GH_TOKEN -u CMUX_NEXT_TUI_ALLOW_DIRTY CMUX_TUI_PIN_BASE=https://127.0.0.1:9/cmux-tui
  GITHUB_API_URL=https://127.0.0.1:9 CMUX_TUI_PUBLIC_GIT_URL="$TMP/no-public-repo.git" CMUX_TUI_TREE_WAIT_SECONDS=0)
run() { # <tree> -> fetch output
  (cd "$1" && "${offline[@]}" bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || true
}
# A fetch never makes the full clone shallow: a shallow clone skips the
# unpushed-commit refusal below.
not_shallow() {
  [[ "$(git -C "$TMP/job" rev-parse --is-shallow-repository)" == false ]] \
    || { printf 'the fetch made the full clone shallow (%s)\n' "$1" >&2; exit 1; }
}

out=$(run "$TMP/job")
if grep -q 'on no remote branch' <<<"$out"; then
  printf 'a pushed tip on a stale mirror was refused:\n%s\n' "$out" >&2; exit 1
fi
grep -q 'is not published' <<<"$out" || { printf 'fetch did not reach the published-tree check:\n%s\n' "$out" >&2; exit 1; }
not_shallow "pushed tip"

# A dirty cmux-tui tree is refused (exit 1), and the refusal explains why an
# nx-remote warm tree is dirty and which mode gives a clean one.
echo dirty > "$TMP/job/cmux-tui/a"
status=0
out=$(cd "$TMP/job" && "${offline[@]}" \
  bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || status=$?
[[ "$status" == 1 ]] || { printf 'a dirty tree was not refused (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }
grep -q 'uncommitted cmux-tui source changes' <<<"$out" || { printf 'dirty refusal lost its reason:\n%s\n' "$out" >&2; exit 1; }
grep -qF 'warm trees are dirty by design' <<<"$out" \
  && grep -qF 'nx-remote --ref <pushed sha>' <<<"$out" \
  || { printf 'dirty refusal does not explain nx-remote warm trees:\n%s\n' "$out" >&2; exit 1; }
git -C "$TMP/job" checkout -q -- cmux-tui/a

# A commit on no branch of origin is still refused before any wait.
echo three > "$TMP/job/cmux-tui/a"
git_q -C "$TMP/job" add cmux-tui/a
git_q -C "$TMP/job" commit -m "local only"
[[ "$(git -C "$TMP/job" log -1 --format=%s)" == "local only" ]] || { echo "setup: the local-only commit was not made" >&2; exit 1; }
not_shallow "before the unpushed commit"
out=$(run "$TMP/job")
grep -q 'on no remote branch' <<<"$out" || { printf 'an unpushed commit was not refused:\n%s\n' "$out" >&2; exit 1; }

# Pin mode: the Cloud app server fields go together, and cloud-server-path names
# the file fetch puts beside the pinned binary (no network).
pin_dir="$TMP/job/scripts/cmux-next"
good="commit=$(printf 'a%.0s' {1..40})
url=https://example.com/cmux-tui
sha256=$(printf 'b%.0s' {1..64})"
printf '%s\ncloud_server_url=https://example.com/cmux-cloud\n' "$good" > "$pin_dir/cmux-tui.pin"
status=0
out=$(cd "$TMP/job" && bash scripts/cmux-next/pin-cmux-tui.sh show 2>&1) || status=$?
[[ "$status" == 1 ]] && grep -q 'cloud_server_url= and cloud_server_sha256= go together' <<<"$out" \
  || { printf 'a half cloud_server pin was not refused (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }
printf '%s\ncloud_server_url=https://example.com/cmux-cloud\ncloud_server_sha256=%s\n' "$good" "$(printf 'c%.0s' {1..64})" > "$pin_dir/cmux-tui.pin"
out=$(cd "$TMP/job" && bash scripts/cmux-next/pin-cmux-tui.sh cloud-server-path --pin)
[[ "$out" == */cmux-tui/target/hosted/$(printf 'a%.0s' {1..40})/cmux-cloud ]] || { printf 'cloud-server-path --pin printed %s\n' "$out" >&2; exit 1; }
# The browser host pin fields go together the same way, and browser-host-path
# names the file fetch puts beside the pinned binary.
printf '%s\nbrowser_host_sha256=%s\n' "$good" "$(printf 'd%.0s' {1..64})" > "$pin_dir/cmux-tui.pin"
status=0
out=$(cd "$TMP/job" && bash scripts/cmux-next/pin-cmux-tui.sh show 2>&1) || status=$?
[[ "$status" == 1 ]] && grep -q 'browser_host_url= and browser_host_sha256= go together' <<<"$out" \
  || { printf 'a half browser_host pin was not refused (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }
printf '%s\nbrowser_host_url=https://example.com/cmux-browser-host\nbrowser_host_sha256=%s\n' "$good" "$(printf 'd%.0s' {1..64})" > "$pin_dir/cmux-tui.pin"
out=$(cd "$TMP/job" && bash scripts/cmux-next/pin-cmux-tui.sh browser-host-path --pin)
[[ "$out" == */cmux-tui/target/hosted/$(printf 'a%.0s' {1..40})/cmux-browser-host ]] || { printf 'browser-host-path --pin printed %s\n' "$out" >&2; exit 1; }
printf 'pin-cmux-tui tests: ok\n'
