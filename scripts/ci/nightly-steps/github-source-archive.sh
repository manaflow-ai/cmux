#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github: "Publish the cmux-next source archive". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
short="${HEAD_SHA:0:11}"
src=(source-archive/cmux-next-source-*.tar.gz)
[[ ${#src[@]} -eq 1 && -f "${src[0]}" ]] || { echo "expected one source archive, found: ${src[*]}" >&2; exit 1; }
vt="$(python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py --rev "$HEAD_SHA" --print-source | sed -n 's/^libghostty-vt source: //p')"
next=()
if [[ "${vt%% *}" != ghostty ]]; then
  next=(--next-name "${vt%% *}" --next-revision "${vt##* }"
    --next-license-manifest "source-archive/${vt%% *}-licenses/SOURCE-MANIFEST.json")
fi
python3 scripts/cmux-next/notices/ghostty_source_archive.py verify --archive "${src[0]}" \
  --license-manifest source-archive/ghostty-licenses/SOURCE-MANIFEST.json \
  --revision "$(git rev-parse "$HEAD_SHA:ghostty")" ${next[@]+"${next[@]}"}
mkdir -p source-out
cp "${src[0]}" "source-out/cmux-next-source-${NIGHTLY_BUILD}.tar.gz"
if existing="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/cmux-next-src-$short" --jq .object.sha 2>/dev/null)"; then
  [[ "$existing" == "$HEAD_SHA" ]] || { echo "tag cmux-next-src-$short points at $existing, not $HEAD_SHA" >&2; exit 1; }
else
  gh api "repos/$GITHUB_REPOSITORY/git/refs" -f "ref=refs/tags/cmux-next-src-$short" -f "sha=$HEAD_SHA" >/dev/null
fi
python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --immutable "source-out/cmux-next-source-${NIGHTLY_BUILD}.tar.gz"
