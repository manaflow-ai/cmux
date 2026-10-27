#!/usr/bin/env bash
# nightly.yml legacy-identity-target: "Compare the cmux NEXT feed with the old feed".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o next-all.xml "${NIGHTLY_NEXT_FEED_BASE}/${LEGACY_APPCAST}"
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o old-all.xml "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
# The old feed's installs run the same updater as cmux NEXT's and
# follow updates.channel (an install from before rings allows only
# cmux-next). Nightly comes first, as before rings: while cmux NEXT
# has a Nightly build newer than every Nightly item of the old feed,
# that build is the candidate (scripts/ci/nightly_next_ring.py select
# on both feeds). Only once the old feed's Nightly is current, and
# with NIGHTLY_NEXT_DEV_RING on, is the newest build of any ring the
# candidate, so a Mac on Dev gets Dev builds in the cmux NIGHTLY
# identity too. publish-nightly-identity-legacy keeps the Nightly
# item beside it (nightly_next_ring.py legacy).
python3 scripts/ci/nightly_next_ring.py select --feed next-all.xml --out next.xml --channel cmux-next
python3 scripts/ci/nightly_next_ring.py select --feed old-all.xml --out old.xml --channel cmux-next
newest() { sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$1" | sort -n | tail -1; }
next_nightly="$(newest next.xml)" old_nightly="$(newest old.xml)"
echo "Nightly: cmux NEXT ${next_nightly:-none}, old feed ${old_nightly:-none}; Dev ring $DEV_RING"
candidate_args=()
if [ "$CURRENT_BUILD_READY" = true ]; then
  [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || { echo "invalid current build '$CURRENT_BUILD'" >&2; exit 1; }
  candidate_args=(--candidate-build "$CURRENT_BUILD" --candidate-url "https://artifact.invalid/${DMG_PREFIX}${CURRENT_BUILD}.dmg")
fi
if [ -n "$next_nightly" ] && [ "$next_nightly" -gt "${old_nightly:-0}" ]; then
  echo "### cmux NIGHTLY-identity: Nightly build $next_nightly is the candidate (cx-x7hwx)" >> "$GITHUB_STEP_SUMMARY"
elif [ "$DEV_RING" = on ]; then
  cp next-all.xml next.xml
  cp old-all.xml old.xml
elif [ -z "$next_nightly" ] && [ "$CURRENT_BUILD_READY" != true ]; then
  echo "### cmux NIGHTLY-identity: no cmux NEXT build is on Nightly yet; the old feed waits (cx-x7hwx)" >> "$GITHUB_STEP_SUMMARY"
  { echo "action=none"; echo "pending_run="; echo "bundle_run="; echo "source_run="; echo "source_sha="; echo "build="; echo "decided=true"; } >> "$GITHUB_OUTPUT"
  exit 0
fi
# A cmux NIGHTLY-identity submission still in Apple's queue is kept by
# publish-nightly-identity-legacy as the artifacts
# cmux-nightly-identity-pending-meta/-bundle of its run: the newest
# unexpired one from a nightly-next run of this repository (never a
# fork's) is continued (never resubmitted): under 6 hours always, up to
# 48 hours while the cmux NEXT feed has no newer build.
pending_args=()
# Newest first; the first candidate whose run is this repository's
# nightly.yml run on nightly-next wins, so a foreign or unreadable
# artifact never hides a valid pending submission.
candidates="$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=cmux-nightly-identity-pending-meta&per_page=20" \
  --jq '[.artifacts[] | select(.expired == false and .workflow_run.head_branch == "nightly-next" and .workflow_run.head_repository_id == .workflow_run.repository_id)] | sort_by(.created_at) | reverse | .[] | "\(.id) \(.workflow_run.id)"')" \
  || { echo "::error title=cmux NIGHTLY-identity could not list pending submissions (cx-x7hwx)::$candidates"; exit 1; }
for candidate in $(tr ' ' ':' <<<"$candidates"); do
  meta_id="${candidate%%:*}" meta_run="${candidate##*:}"
  origin="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$meta_run" --jq '"\(.path) \(.event)"' 2>/dev/null || true)"
  case "$origin" in
    ".github/workflows/nightly.yml push"|".github/workflows/nightly.yml workflow_dispatch") ;;
    *) echo "::warning::skipping pending artifact $meta_id of run $meta_run ($origin)"; continue ;;
  esac
  rm -rf pending && mkdir -p pending
  if gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$meta_id/zip" > pending/meta.zip && unzip -o -q pending/meta.zip -d pending && [ -f pending/pending.json ]; then
    # An accepted submission's metadata is re-stored by later runs and
    # names the original bundle run. A meta whose bundle is confirmed
    # gone (expired or deleted) is skipped; an API error keeps it.
    bundle_run="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("bundle_run") or sys.argv[2])' pending/pending.json "$meta_run")"
    if bundles="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$bundle_run/artifacts?name=cmux-nightly-identity-pending-bundle" --jq '[.artifacts[] | select(.expired == false)] | length')" \
       && [ "$bundles" = 0 ]; then
      echo "::warning::skipping pending artifact $meta_id of run $meta_run: the bundle of run $bundle_run is gone"
      continue
    fi
    # The target compares a pending build with the old feed's Nightly
    # only, so a Dev build the old feed already lists would look
    # continuable again; it is stale.
    pending_build="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["build"])' pending/pending.json || true)"
    if [ -n "$pending_build" ] && ! grep -q "<sparkle:version>${pending_build}</sparkle:version>" next.xml; then
      echo "::warning::skipping pending artifact $meta_id of run $meta_run: accepted build $pending_build is not on the live cmux NEXT Nightly feed"
      continue
    fi
    if [ -n "$pending_build" ] && grep -q "<sparkle:version>${pending_build}</sparkle:version>" old-all.xml; then
      echo "pending build $pending_build of run $meta_run is already in the old feed; not continued"
      break
    fi
    pending_args=(--pending-meta pending/pending.json --pending-run "$meta_run" --now "$(date +%s)")
    break
  fi
  echo "::warning::could not read pending artifact $meta_id of run $meta_run; trying an older one"
done
# Only real failures count (comments "Build N failed:" on the failure
# issue): Apple refused the copy, or a check, the smoke or the
# publication failed. A submission still in Apple's queue never counts.
# Two counted failures stop a build (the script); a newer build is tried.
: > failures.txt
number="$(./scripts/ci/nightly-next-legacy-failure-issue.sh "$GITHUB_REPOSITORY" || echo "::warning::could not search for the failure issue; counting no failures" >&2)"
if [ -n "$number" ]; then
  { gh api "repos/$GITHUB_REPOSITORY/issues/$number" --jq .body; gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$number/comments" --jq '.[].body'; } > failures.txt \
    || echo "::warning::could not read the failure issue #$number; counting no failures"
fi
# Every commit in NIGHTLY_LEGACY_REQUIRED_COMMITS must be in the
# build's commit (scripts/ci/nightly-next-legacy-requirement.sh). A
# refused build is neither continued nor submitted, and the next
# newer one is checked; a refused pending submission is deleted. An
# error fails closed. Refusals are recorded, not counted.
echo "cmux NIGHTLY-identity requirement in use: required: ${REQUIRED:-none}"
echo "### cmux NIGHTLY-identity requirement in use: required: ${REQUIRED:-none}" >> "$GITHUB_STEP_SUMMARY"
refuse_args=()
notes=""
action=none build="" pending_run="" bundle_run=""
for _ in 1 2 3; do
  decision="$(python3 scripts/ci/nightly-next-legacy-target.py next.xml old.xml "$DMG_PREFIX" --max-pending-hours 6 --max-same-build-hours 48 \
    --failure-log failures.txt --max-failures 2 ${candidate_args[@]+"${candidate_args[@]}"} ${pending_args[@]+"${pending_args[@]}"} ${refuse_args[@]+"${refuse_args[@]}"})"
  action="$(sed -n 's/^action=//p' <<<"$decision")"
  build="$(sed -n 's/^build=//p' <<<"$decision")"
  pending_run="$(sed -n 's/^pending_run=//p' <<<"$decision")"
  bundle_run="$(sed -n 's/^bundle_run=//p' <<<"$decision")"
  [ "$action" != none ] || break
  # shellcheck disable=SC2086 # REQUIRED is a space-separated SHA list
  rc=0
  check="$(NOTES_BASE="${NIGHTLY_NEXT_FEED_BASE}/notes" ./scripts/ci/nightly-next-legacy-requirement.sh "$GITHUB_REPOSITORY" "$build" $REQUIRED)" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "build $build meets the requirement ($check)"
    break
  fi
  # Only exit 3 is a refusal. An error (a rate-limited API read, run
  # 40239403743 on 2026-10-25) refused the build and left the old feed
  # 1h+ behind with every legacy job skipped: fail instead, so the job
  # is red and the feed watch re-runs it.
  if [ "$rc" != 3 ]; then
    echo "::error title=cmux NIGHTLY-identity requirement check failed (cx-x7hwx)::build $build: $check"
    exit 1
  fi
  echo "::warning title=cmux NIGHTLY-identity build $build refused (cx-x7hwx)::$check"
  refuse_args+=(--refuse-build "$build")
  note="Build $build skipped (not counted): $check."
  if [ "$action" = continue ] && [[ "$check" == missing* ]]; then
    for run in "$pending_run" "$bundle_run"; do
      for name in cmux-nightly-identity-pending-meta cmux-nightly-identity-pending-bundle; do
        gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/artifacts?name=$name" --jq '.artifacts[].id' \
          | while IFS= read -r id; do gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id" || true; done
      done
    done
    note="$note Its pending submission (runs $pending_run/$bundle_run) was deleted; it is never published."
  fi
  # Recorded on the issue once per build; every run's summary has it.
  if ! grep -q "^Build $build skipped" failures.txt; then notes="$notes$note"$'\n'; fi
  echo "- $note" >> "$GITHUB_STEP_SUMMARY"
  action=none build="" pending_run="" bundle_run=""
done
source_run=""
source_sha=""
if [ "$action" = new ] && [ "$CURRENT_BUILD_READY" = true ] && [ "$build" = "$CURRENT_BUILD" ]; then
  source_run="$CURRENT_RUN"
  source_sha="$CURRENT_BUILD_SHA"
fi
echo "source_run=$source_run" >> "$GITHUB_OUTPUT"
echo "source_sha=$source_sha" >> "$GITHUB_OUTPUT"
if [ -n "$notes" ]; then
  body="$notes"$'\n'"Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID (requirement: NIGHTLY_LEGACY_REQUIRED_COMMITS=${REQUIRED:-none})"
  if issue="$(./scripts/ci/nightly-next-legacy-failure-issue.sh "$GITHUB_REPOSITORY")"; then
    if [ -n "$issue" ]; then
      gh api "repos/$GITHUB_REPOSITORY/issues/$issue/comments" -f body="$body" >/dev/null || echo "::warning::could not record the refusal on issue #$issue"
    else
      gh api "repos/$GITHUB_REPOSITORY/issues" -f title="cmux NIGHTLY-identity publication failed (nightly.yml publish-nightly-identity-legacy)" -f body="$body" >/dev/null \
        || echo "::warning::could not open the failure issue for the refusal"
    fi
  else
    echo "::warning::could not search for the failure issue; the refusal is in this run's summary only"
  fi
fi
{ echo "action=$action"; echo "pending_run=$pending_run"; echo "bundle_run=$bundle_run"; echo "build=$build"; echo "decided=true"; } >> "$GITHUB_OUTPUT"
if [ -n "$build" ]; then
  echo "### cmux NIGHTLY-identity: $action build $build for the old feed (cx-x7hwx)" >> "$GITHUB_STEP_SUMMARY"
else
  echo "### cmux NIGHTLY-identity: old feed is current (cx-x7hwx)" >> "$GITHUB_STEP_SUMMARY"
fi
