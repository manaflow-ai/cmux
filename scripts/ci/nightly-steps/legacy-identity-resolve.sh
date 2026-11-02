#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Resolve the attempt". Moved out of the workflow to
# keep nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Apple's answer as the signing job saw it (a notary log or a stapled ticket).
set -euo pipefail
apple="$APPLE"
refused="$REQUIREMENT_REFUSED"
decision="$(python3 scripts/ci/nightly-next-legacy-resolve.py --action "$LEGACY_ACTION" --pending "$PENDING" \
  --notarize "$NOTARIZE" --published "$PUBLISHED" --apple "$apple" --requirement-refused "$refused")"
echo "$decision" >> "$GITHUB_OUTPUT"
echo "attempt: action=$LEGACY_ACTION pending=$PENDING notarize=$NOTARIZE published=$PUBLISHED apple=$apple -> $(tr '\n' ' ' <<<"$decision")"
if [ "$LEGACY_ACTION" = continue ] && grep -Fxq retire=true <<<"$decision"; then
  for run in "$PENDING_RUN" "$BUNDLE_RUN"; do
    for name in cmux-nightly-identity-pending-meta cmux-nightly-identity-pending-bundle; do
      gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/artifacts?name=$name" --jq '.artifacts[].id' \
        | while IFS= read -r id; do gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id" || true; done
    done
  done
  echo "retired the pending submission of runs $PENDING_RUN/$BUNDLE_RUN"
elif [ "$LEGACY_ACTION" = continue ]; then
  echo "kept the pending submission of run $BUNDLE_RUN"
fi
# Apple accepted it but a later step failed: store metadata that marks
# the bundle accepted, so later runs continue it with no time limit
# and never submit the build again (newest metadata wins).
if [ "$LEGACY_ACTION" = continue ] && grep -Fxq mark_accepted=true <<<"$decision"; then
  [ -f pending/pending.json ] || { echo "the signing job left no metadata of the continued submission" >&2; exit 1; }
  mkdir -p accepted-meta
  python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); m["accepted"] = True; m["bundle_run"] = sys.argv[2]; json.dump(m, open(sys.argv[3], "w"))' \
    pending/pending.json "$BUNDLE_RUN" accepted-meta/pending.json
  cat accepted-meta/pending.json
fi
