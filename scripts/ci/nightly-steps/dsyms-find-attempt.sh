#!/usr/bin/env bash
# nightly.yml keep-published-dsyms: "Find the attempt that compiled the published build". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build commit $BUILD_SHA" >&2; exit 1; }
[[ "$BUILD" =~ ^([0-9]+)([0-9]{2})$ ]] || { echo "invalid build $BUILD" >&2; exit 1; }
# The build number is the compiling run's id and two-digit attempt (build-nightly-app's
# remote_daemon step; an unsigned resume keeps its source's number), so it names the
# exact binary. Take only that run's artifact, created during that attempt.
run="${BASH_REMATCH[1]}" attempt="$((10#${BASH_REMATCH[2]}))"
window="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/attempts/$attempt" --jq '[.run_started_at, .updated_at] | @tsv')"
started="${window%%$'\t'*}" ended="${window##*$'\t'}"
id="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/artifacts?per_page=100&name=nightly-next-dsyms-$BUILD_SHA" \
  --jq "[.artifacts[] | select(.expired | not) | select(.created_at >= \"$started\" and .created_at <= \"$ended\")] | if length == 1 then .[0].id else empty end")"
[ -n "$id" ] || { echo "::warning title=No dSYMs to keep::run $run attempt $attempt has no single live nightly-next-dsyms-$BUILD_SHA; Sentry has this build's symbols"; exit 1; }
echo "run=$run" >> "$GITHUB_OUTPUT"
echo "artifact=$id" >> "$GITHUB_OUTPUT"
