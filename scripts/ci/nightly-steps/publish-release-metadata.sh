#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish verified nightly release metadata". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# nightly-next commits change .github/workflows relative to main, and
# GitHub refuses the Actions token any release create/update that targets
# such a commit. nightly-next therefore publishes its release metadata
# with the release App token; other channels keep the Actions token.
set -euo pipefail
{
  printf "Automated %s build for \`%s\` from \`%s\`.\n" "$CHANNEL" "$BUILD_SHORT_SHA" "$REF_NAME"
  printf "Published commit: \`%s\`.\n" "$BUILD_SHA"
  printf "Branch tip \`%s\`; the build commit is %s commits and %s h behind it. The bundled cmux-tui daemon is in cmux.app/Contents/Resources/bin/cmux-tui.version: its tree is the build commit's, or an older commit's (tree_from=) when that tree was not published.\n" "$TIP_SHA" "$BEHIND" "$BEHIND_HOURS"
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
