#!/usr/bin/env bash
# nightly.yml find-nightly-next-recovery: "List newer pending nightly-next notarizations". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
candidates="$(python3 scripts/ci/find-nightly-next-recovery.py \
  --repo "$GITHUB_REPOSITORY" --current-run-id "$GITHUB_RUN_ID" --limit 5 "${feeds[@]}")"
# Never recover a build that lacks a required commit or does not
# descend from the commit the NEXT feed serves (run 38868028629
# published 0664bd98 from 10-14 over newer builds). The run head is an
# upper bound of its build commit, so a refusal here is never wrong;
# recover and publish-nightly check the exact build commit again.
keep=""
while IFS=$'\t' read -r run_id head; do
  [ -n "$run_id" ] || continue
  # NIGHTLY_NEXT_TREE_AT_INSTALL: never a build whose tree marker check did not pass.
  if ! why="$(bash scripts/ci/nightly-steps/recover-tree-marker-ok.sh "$run_id")"; then
    echo "::notice title=Recovery refused::run $run_id: $why"
    echo "- refused run $run_id: $why" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi
  if verdict="$(bash scripts/ci/nightly-next-recovery-lineage.sh "$GITHUB_REPOSITORY" "$CHANNEL_RELEASE_TAG" "$head" </dev/null)"; then
    keep="$keep $run_id"
  else
    echo "::notice title=Recovery refused::run $run_id: $verdict"
    echo "- refused run $run_id: $verdict" >> "$GITHUB_STEP_SUMMARY"
  fi
done < <(python3 -I -c 'import json, sys; [print("%s\t%s" % (c["run_id"], c["head_sha"])) for c in json.load(sys.stdin)]' <<<"$candidates")
candidates="$(KEEP="$keep" python3 -I -c 'import json, os, sys; keep = set(os.environ.get("KEEP", "").split()); print(json.dumps([c for c in json.load(sys.stdin) if str(c["run_id"]) in keep]))' <<<"$candidates")"
echo "candidates=$candidates" >> "$GITHUB_OUTPUT"
if [ "$candidates" = "[]" ]; then
  echo "found=false" >> "$GITHUB_OUTPUT"
else
  echo "found=true" >> "$GITHUB_OUTPUT"
  echo "### Pending nightly-next notarizations" >> "$GITHUB_STEP_SUMMARY"
  echo "$candidates" | python3 -c 'import json, sys; [print("- run %s build %s" % (c["run_id"], c["build"])) for c in json.load(sys.stdin)]' >> "$GITHUB_STEP_SUMMARY"
fi
