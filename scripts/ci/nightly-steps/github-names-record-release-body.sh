#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github-names: "Record the published build in the release body". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The release body with the cmux-published-sha marker decide reads, as publish-nightly's
# Record step writes it on the other channels.
set -euo pipefail
{
  printf '<!-- cmux-published-sha: %s -->\n' "$BUILD_SHA"
  printf "Automated %s build for \`%s\` from \`%s\`.\n" "$CHANNEL" "${BUILD_SHA:0:7}" "$REF_NAME"
  printf "Published commit: \`%s\`.\n" "$BUILD_SHA"
  printf "Built at the commit whose cmux-tui tree is published (app and daemon from one commit); branch tip \`%s\`, %s commits and %s h behind it.\n" "$TIP_SHA" "$BEHIND" "$BEHIND_HOURS"
  printf '%s\n' "$DOWNLOADS"
  if [ -s "$RUNNER_TEMP/nightly-prs.md" ]; then
    printf '\n'
    cat "$RUNNER_TEMP/nightly-prs.md"
  fi
} > "$RUNNER_TEMP/nightly-release-body.md"
expect=()
names=()
read -ra names <<<"$UPLOADED_ASSETS"
for name in "${names[@]}"; do expect+=(--expect-asset "$name"); done
"$RUNNER_TEMP/still-newest" || exit 0
python3 "$PUBLISH_TOOLING/ci/finalize-release.py" publish \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" --release-id "$RELEASE_ID" \
  --name "$RELEASE_NAME" --target-commitish "$BUILD_SHA" \
  --body-file "$RUNNER_TEMP/nightly-release-body.md" \
  --prerelease true --make-latest false "${expect[@]}"
