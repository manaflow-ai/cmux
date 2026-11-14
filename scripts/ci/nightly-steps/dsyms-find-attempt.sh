#!/usr/bin/env bash
# nightly.yml keep-published-dsyms and sentry-dsyms-nightly: "Find the attempt that compiled the published build".
# Moved out of the workflow to keep nightly.yml under GitHub's workflow file size limit; the step's env: still sets
# every input. DSYMS_NAMES lists the dSYM artifacts to find, space-separated and without their -$BUILD_SHA suffix
# (default nightly-next-dsyms). The first must exist; the others (the fast build's cmux-tui dSYMs) may be missing.
# Outputs: run, artifact (the first name's id) and artifacts (every found id, comma-separated).
set -euo pipefail
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build commit $BUILD_SHA" >&2; exit 1; }
[[ "$BUILD" =~ ^([0-9]+)([0-9]{2})$ ]] || { echo "invalid build $BUILD" >&2; exit 1; }
# The build number is the compiling run's id and the two-digit attempt that fixed it
# (resolve-nightly-cmux-tui-client; an unsigned resume keeps its source's number). A
# re-run of failed jobs keeps that number, so the app may have compiled in that attempt
# or a later one: take that run's newest artifact created since that attempt began (an
# app compile that already succeeded is not re-run, so that is the published binary's).
run="${BASH_REMATCH[1]}" attempt="$((10#${BASH_REMATCH[2]}))"
started="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/attempts/$attempt" --jq '.run_started_at')"
read -r -a names <<< "${DSYMS_NAMES:-nightly-next-dsyms}"
ids=()
for name in "${names[@]}"; do
  id="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/artifacts?per_page=100&name=$name-$BUILD_SHA" \
    --jq "[.artifacts[] | select(.expired | not) | select(.created_at >= \"$started\")] | sort_by(.created_at) | last | .id // empty")"
  if [ -n "$id" ]; then
    ids+=("$id")
  elif [ "${#ids[@]}" -eq 0 ]; then
    echo "::warning title=No dSYMs to keep::run $run attempt $attempt has no live $name-$BUILD_SHA since then; Sentry has this build's symbols"
    exit 1
  fi
done
echo "run=$run" >> "$GITHUB_OUTPUT"
echo "artifact=${ids[0]}" >> "$GITHUB_OUTPUT"
echo "artifacts=$(IFS=,; echo "${ids[*]}")" >> "$GITHUB_OUTPUT"
