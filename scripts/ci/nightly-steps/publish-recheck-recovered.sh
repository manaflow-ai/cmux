#!/usr/bin/env bash
# nightly.yml publish-nightly: "Recheck the recovered build against both feeds". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Inside the publication lock: a run that published meanwhile may have
# moved a feed above either this run's own nightly-next build or a
# recovered build. The early check precedes signing and notarization.
# Two runs can take the same recovered build; the later one finds it
# already on the feed and publishes nothing (run 38689026338). A build
# below any feed still fails.
set -euo pipefail
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
# cmux NEXT builds run side by side and publication is latest-wins: a build a newer one already
# published past is superseded, a no-op like an already published one, not a failure (run
# 40825878411's 4082587841101 after 4082702109901 opened a failure issue). Classic keeps its
# floor check.
superseded=()
[ "${TRACK:-}" = nightly-next ] && superseded=(--superseded-ok)
result="$(python3 "$PUBLISH_TOOLING/ci/nightly_version.py" check-build --already-published-ok ${superseded[@]+"${superseded[@]}"} --build "$NIGHTLY_BUILD" "${feeds[@]}")"
printf '%s\n' "$result"
if [ "$(tail -n 1 <<< "$result")" = superseded=true ]; then
  echo "::notice title=Superseded::build $NIGHTLY_BUILD is older than what the feed already serves; a newer build published first, so nothing to do"
  { echo "already_published=true"; echo "superseded=true"; } >> "$GITHUB_OUTPUT"
elif grep -qx already_published=true <<< "$result"; then
  if [[ "${TRACK:-}" = nightly-next && "${GITHUB_RUN_ATTEMPT:-1}" =~ ^[0-9]+$ ]] && (( 10#${GITHUB_RUN_ATTEMPT:-1} > 1 )); then
    # A previous attempt may have committed the feed CAS, then failed to upload
    # its GitHub handoff artifact. Continue through the normal final gate and
    # CAS: only the exact live build AND source can reuse the accepted bytes.
    # A newer feed above still takes the superseded branch, including on retry.
    echo "::notice title=Repair publication handoff::build $NIGHTLY_BUILD is already published; retrying its checked handoff"
  else
    echo "::notice title=Nothing to publish::build $NIGHTLY_BUILD is already published; nothing to do"
    echo "already_published=true" >> "$GITHUB_OUTPUT"
  fi
fi
