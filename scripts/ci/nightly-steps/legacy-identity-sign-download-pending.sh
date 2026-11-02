#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Download the pending cmux NIGHTLY-identity submission". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
for run in "$PENDING_RUN" "$BUNDLE_RUN"; do
  [[ "$run" =~ ^[0-9]+$ ]] || { echo "invalid pending run '$run'" >&2; exit 1; }
  # Only this repository's own nightly.yml runs on nightly-next made it.
  origin="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" --jq '"\(.path) \(.event) \(.head_branch) \(.head_repository.full_name)"')"
  case "$origin" in
    ".github/workflows/nightly.yml push nightly-next $GITHUB_REPOSITORY"|".github/workflows/nightly.yml workflow_dispatch nightly-next $GITHUB_REPOSITORY") ;;
    *) echo "pending run $run is not this repository's nightly.yml run on nightly-next: $origin" >&2; exit 1 ;;
  esac
done
if ! gh run download "$BUNDLE_RUN" --repo "$GITHUB_REPOSITORY" -n cmux-nightly-identity-pending-bundle -D pending; then
  # Metadata whose bundle is confirmed gone can never continue: retire
  # it so the next run submits anew instead of waiting out the limit.
  # Any API error keeps it.
  ./scripts/ci/nightly-next-legacy-orphan-meta.sh "$GITHUB_REPOSITORY" "$BUNDLE_RUN" >&2
  if [ "$PENDING_RUN" != "$BUNDLE_RUN" ]; then
    ./scripts/ci/nightly-next-legacy-orphan-meta.sh "$GITHUB_REPOSITORY" "$PENDING_RUN" "$BUNDLE_RUN" >&2
  fi
  echo "could not download the bundle of pending run $BUNDLE_RUN" >&2
  exit 1
fi
python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); assert str(m["build"]) == sys.argv[2], (m["build"], sys.argv[2]); print("pending submission", m["submission_id"], "of build", m["build"])' pending/pending.json "$NIGHTLY_BUILD"
mkdir -p legacy-app legacy-out
tar -C legacy-app -xzf pending/app.tar.gz
cp pending/release.dmg legacy-out/release.dmg
# The accepted first DMG of a handed-off stapled-app DMG (6 h fallback).
if [ -f pending/release.first.dmg ]; then cp pending/release.first.dmg legacy-out/release.first.dmg; fi
cp pending/legacy.notarization.state "$RUNNER_TEMP/legacy.notarization.state"
