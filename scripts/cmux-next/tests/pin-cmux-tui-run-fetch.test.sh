#!/usr/bin/env bash
# pin-cmux-tui.sh probe in a shallow CI checkout while many cmux-tui artifacts
# runs are active (a burst of lane-branch pushes): the commits of those runs are
# fetched together, by exact SHA, with no tags, depth 1 and no blobs, inside
# CMUX_TUI_TREE_RUN_FETCH_SECONDS. One depth-1 fetch with blobs per run held
# cmux-next path routing past its 10-minute limit (2026-10-27).
# No network: origin is a local bare repo, the CDN and the GitHub API are stubs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf 'output:\n%s\n' "$2" >&2; exit 1; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo base > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m base
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"
git -C "$TMP/origin.git" config uploadpack.allowFilter true

# Lane branches, each with its own cmux-tui tree, and one commit on another
# branch whose tree is the one under test: the active publisher to find.
lane_shas=()
for n in 1 2 3 4 5 6; do
  git_q -C "$TMP/src" checkout -B "cp/$n" feat-cmux-next
  echo "lane $n" > "$TMP/src/cmux-tui/a"
  git_q -C "$TMP/src" commit -am "lane $n"
  lane_shas+=("$(git -C "$TMP/src" rev-parse HEAD)")
  git_q -C "$TMP/src" push "$TMP/origin.git" "cp/$n"
done
git_q -C "$TMP/src" checkout -B feat-cmux-next-acpmux feat-cmux-next
echo wanted > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" commit -am "the tree under test"
publisher=$(git -C "$TMP/src" rev-parse HEAD)
git_q -C "$TMP/src" push "$TMP/origin.git" feat-cmux-next-acpmux
# The job: a shallow checkout of a commit with that same tree (an app-only change on top).
git_q -C "$TMP/src" checkout -B job "$publisher"
echo app > "$TMP/src/app.swift"
git_q -C "$TMP/src" add app.swift
git_q -C "$TMP/src" commit -m app
git_q -C "$TMP/src" push "$TMP/origin.git" job
git_q clone --depth=1 --branch job "file://$TMP/origin.git" "$TMP/job"
[[ "$(git -C "$TMP/job" rev-parse --is-shallow-repository)" == true ]] || fail "setup: the job checkout is not shallow"
for sha in "${lane_shas[@]}" "$publisher"; do
  ! git -C "$TMP/job" cat-file -e "$sha^{commit}" 2>/dev/null || fail "setup: the job checkout already has $sha"
done

# A git shim logs every fetch; SLOW_FETCH makes each fetch hang.
mkdir -p "$TMP/bin"
real_git=$(command -v git)
cat > "$TMP/bin/git" <<SHIM
#!/usr/bin/env bash
for arg; do
  if [[ "\$arg" == fetch ]]; then
    printf '%s\n' "\$*" >> "$TMP/fetches.log"
    [[ -z "\${SLOW_FETCH:-}" ]] || sleep 30 </dev/null >/dev/null 2>&1
    break
  fi
done
exec "$real_git" "\$@"
SHIM
chmod +x "$TMP/bin/git"
# The runs list: the lanes' runs first (newest), the publisher's last.
runs_json() {
  python3 -c '
import json, sys
lanes, publisher = sys.argv[1].split(), sys.argv[2]
runs = [{"status": "queued", "head_sha": s, "head_branch": "cp/%d" % i} for i, s in enumerate(lanes, 1)]
runs.append({"status": "in_progress", "head_sha": publisher, "head_branch": "feat-cmux-next-acpmux"})
print(json.dumps({"workflow_runs": runs}))' "${lane_shas[*]}" "$publisher"
}
runs_json > "$TMP/runs.json"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
for arg; do url="\$arg"; done
case "\$url" in
  *head_sha=*) want="\${url##*head_sha=}"; want="\${want%%&*}"
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps({"workflow_runs": [r for r in d["workflow_runs"] if r["head_sha"] == sys.argv[2]]}))' "$TMP/runs.json" "\$want" ;;
  */actions/workflows/cmux-tui-artifacts.yml/runs\?per_page=*) cat "$TMP/runs.json" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$TMP/bin/curl"

# A scheduled DEV dispatch looks once (wait 0) for a same-tree active run.
probe() {
  : > "$TMP/gh-output"; : > "$TMP/fetches.log"
  status=0
  out=$(cd "$TMP/job" && env -u CI_JOB_DIR -u CMUX_TUI_TREE_PUBLISHER_SHA -u CMUX_TUI_TREE_DISPATCH \
    PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_OUTPUT="$TMP/gh-output" GITHUB_REPOSITORY=o/r GITHUB_API_URL=https://api.test GH_TOKEN=test-token \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_RECHECK_SECONDS=0 \
    CMUX_TUI_PUBLIC_GIT_URL="file://$TMP/no-public-repo.git" "$@" \
    bash scripts/cmux-next/pin-cmux-tui.sh probe 2>&1) || status=$?
  state=$(awk -F= '$1 == "tree_state" { print $2 }' "$TMP/gh-output")
}

# (a) Every missing run commit comes in one exact-SHA fetch from origin, and
# the same-tree run on a cmux-next branch is found and deferred to.
probe
[[ "$status" == 0 ]] || fail "(a) probe exited $status" "$out"
[[ "$state" == deferred ]] || fail "(a) expected tree_state=deferred, got '${state}'" "$out"
grep -qF "active artifacts run for $publisher has the same tree" <<<"$out" || fail "(a) the same-tree run was not found" "$out"
[[ "$(wc -l < "$TMP/fetches.log" | tr -d ' ')" == 1 ]] || fail "(a) expected one batched fetch, got:" "$(cat "$TMP/fetches.log")"
fetch=$(cat "$TMP/fetches.log")
for flag in --no-tags --no-recurse-submodules --no-write-fetch-head --depth=1 --filter=blob:none; do
  grep -qF -- " $flag " <<<"$fetch " || fail "(a) the run-commit fetch lacks $flag: $fetch"
done
for sha in "${lane_shas[@]}" "$publisher"; do
  grep -qF " origin " <<<"$fetch" && grep -qF " $sha" <<<"$fetch" || fail "(a) the batched fetch misses $sha: $fetch"
done
# No refspec, branch name or wildcard: only the run commits' SHAs follow the remote.
after_remote=${fetch#* origin }
for word in $after_remote; do
  [[ "$word" =~ ^[0-9a-f]{40}$ ]] || fail "(a) the run-commit fetch names more than exact SHAs: $fetch"
done
[[ "$(git -C "$TMP/job" rev-parse --is-shallow-repository)" == true ]] || fail "(a) the job checkout lost its shallow marker"

# (b) No fetch budget: nothing is fetched, the unread runs make the answer
# unknown (never "no publisher"), and the probe still writes its state at once.
rm -rf "$TMP/job2"; git_q clone --depth=1 --branch job "file://$TMP/origin.git" "$TMP/job2"
mv "$TMP/job" "$TMP/job-a"; mv "$TMP/job2" "$TMP/job"
probe CMUX_TUI_TREE_RUN_FETCH_SECONDS=0
[[ "$status" == 0 && -n "$state" ]] || fail "(b) the probe wrote no state (exit $status)" "$out"
[[ ! -s "$TMP/fetches.log" ]] || fail "(b) a fetch ran with no budget:" "$(cat "$TMP/fetches.log")"
grep -qF "7 active run commits were not fetched within 0s" <<<"$out" || fail "(b) the unread runs were not reported" "$out"

# (c) A hanging fetch is stopped at the budget: the probe answers in seconds.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  started=$SECONDS
  probe SLOW_FETCH=1 CMUX_TUI_TREE_RUN_FETCH_SECONDS=2
  took=$((SECONDS - started))
  [[ "$status" == 0 && -n "$state" ]] || fail "(c) the probe wrote no state (exit $status)" "$out"
  (( took < 20 )) || fail "(c) a hanging run-commit fetch held the probe ${took}s past a 2 s budget" "$out"
  grep -qF "were not fetched within 2s" <<<"$out" || fail "(c) the unread runs were not reported" "$out"
else
  echo "note: (c) skipped: no timeout(1) on this host"
fi
printf 'pin-cmux-tui run-fetch tests: ok\n'
