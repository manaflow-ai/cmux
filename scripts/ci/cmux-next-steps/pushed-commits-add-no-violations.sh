#!/usr/bin/env bash
# cmux-next.yml checks: "Pushed commits add no violations". Moved out of the workflow to keep cmux-next.yml under
# its size budget (tests/test_ci_workflow_file_size.py); the step's env: still sets every input, and the step runs
# it with `bash -e` as GitHub's default `bash -e {0}` ran the inline block.
# Sidebar look owner sweep (plans/cmux-next/sidebar-owner.md): every commit since the check landed,
# not only this push's, so a commit from an old hook copy or a cancelled run is still named.
# From where the check widened to the whole sidebar package (Views/ only before; that range swept clean).
sidebar_from=342462ca6ee97db1d23f013ad0d58dc942673c82
sweep=0
# Commits and trees only (--filter=blob:none): the sweep reads messages and changed paths, and
# the gate's few blobs come on demand. The full fetch of 2000 commits took 2-7 min of the job's
# 10 on a push (401 s measured from a fresh depth-2 clone; blobless: 27 s). Same history as before.
# --deepen on a full clone is a no-op fetch; only a shallow checkout deepens.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --no-recurse-submodules --no-tags --quiet --filter=blob:none --deepen=2000 origin "$GITHUB_SHA" || true
else
  git fetch --no-recurse-submodules --no-tags --quiet --filter=blob:none origin "$GITHUB_SHA" || true
fi
# A pull request is judged on its own commits (HEAD^1..HEAD of the merge): a base commit without the
# owner's record is a warning naming it here, and stays an error on every push sweep of the branch.
own=()
# pull_request only: there HEAD is GitHub's merge of the PR into its base; a dispatch runs on a branch tip.
[[ "$EVENT_NAME" == pull_request ]] && own=(--own-range HEAD^1..HEAD)
if git merge-base --is-ancestor "$sidebar_from" HEAD 2>/dev/null; then
  python3 -I scripts/cmux-next/prepush-gate.py --only sidebar --commits "$sidebar_from..HEAD" "${own[@]}" \
    | tee -a "$GITHUB_STEP_SUMMARY" || sweep=$?
fi
if [[ "$EVENT_NAME" != push ]]; then
  python3 -I scripts/cmux-next/prepush-gate.py --base HEAD^1 --head HEAD
  exit "$sweep"
fi
range="HEAD^1..HEAD"
if [[ -n "$BEFORE" && "$BEFORE" != 0000000000000000000000000000000000000000 ]]; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=200)
  git fetch --no-recurse-submodules --no-tags --quiet --filter=blob:none ${depth[@]+"${depth[@]}"} origin "$GITHUB_SHA" "$BEFORE" || true
  if git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then range="$BEFORE..HEAD"; fi
fi
python3 -I scripts/cmux-next/prepush-gate.py --commits "$range" | tee -a "$GITHUB_STEP_SUMMARY"
exit "$sweep"
