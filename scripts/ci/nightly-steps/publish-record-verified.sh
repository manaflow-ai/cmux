#!/usr/bin/env bash
# nightly.yml publish-nightly: "Record verified nightly publication". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The marker is written only after immutable assets, aliases, release
# metadata, and every appcast have succeeded. A rerun can therefore use
# it as an idempotency record without mistaking a partial publication for
# a complete one.
set -euo pipefail
{
  printf '<!-- cmux-published-sha: %s -->\n' "$BUILD_SHA"
  printf "Automated %s build for \`%s\` from \`%s\`.\n" "$CHANNEL" "$BUILD_SHORT_SHA" "$REF_NAME"
  printf "Published commit: \`%s\`.\n" "$BUILD_SHA"
  printf "Built at the commit whose cmux-tui tree is published (app and daemon from one commit); branch tip \`%s\`, %s commits and %s h behind it.\n" "$TIP_SHA" "$BEHIND" "$BEHIND_HOURS"
  printf '%s\n' "$DOWNLOADS"
  # nightly-next only: the PRs since the previous published build (notes step).
  if [ -s "$RUNNER_TEMP/nightly-prs.md" ]; then
    printf '\n'
    cat "$RUNNER_TEMP/nightly-prs.md"
  fi
} > "$RUNNER_TEMP/nightly-release-body.md"
expect=()
names=()
read -ra names <<<"$UPLOADED_ASSETS"
for name in "${names[@]}"; do expect+=(--expect-asset "$name"); done
python3 "$PUBLISH_TOOLING/ci/finalize-release.py" publish \
  --repo "$GITHUB_REPOSITORY" --tag "$RELEASE_TAG" --release-id "$RELEASE_ID" \
  --name "$RELEASE_NAME" --target-commitish "$BUILD_SHA" \
  --body-file "$RUNNER_TEMP/nightly-release-body.md" \
  --prerelease true --make-latest false "${expect[@]}"
