#!/usr/bin/env bash
# Publishes the corresponding-source archive of one iOS release
# (IOS-SOURCE-ARCHIVE-PER-RELEASE). CI only, from the iOS release workflows'
# publish-source-archive job, which runs only while
# vars.CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE is 1 and only after the upload succeeded.
#
#   publish-ios-source-archive.sh <build number> <commit> <archive dir>
#
# <archive dir> is the cmux-ios-source-archive artifact that
# cmux-next-source-archive.yml built for <commit> before the upload. The script
# checks that the archive's ghostty-next tree is the GhosttyNextKit pin's Ghostty
# revision (the iOS app links that kit, z2d included) and verifies the archive
# against its license manifests. It then tags <commit> cmux-next-src-<11
# characters> (the public tag the offer names) and attaches the archive as
# cmux-ios-source-<build>.tar.gz to the GitHub release ios-source, the name the
# iOS Acknowledgements pane's z2d offer gives. Assets are never removed: App
# Store builds stay downloadable.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <build number> <commit> <archive dir>" >&2; exit 2; }
build="$1" commit="$2" dir="$3"
[[ "$build" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "error: build number '$build' is not a CFBundleVersion" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: '$commit' is not a 40-character commit" >&2; exit 1; }
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE=ios-source

src=("$dir"/cmux-next-source-*.tar.gz)
[[ ${#src[@]} -eq 1 && -f "${src[0]}" ]] || { echo "error: expected one source archive in $dir, found: ${src[*]}" >&2; exit 1; }

vt="$(python3 "$ROOT/scripts/cmux-next/notices/check_ghostty_vt_notices.py" --repo "$ROOT" --rev "$commit" --print-source | sed -n 's/^libghostty-vt source: //p')"
vt_name="${vt%% *}" vt_revision="${vt##* }"
pin_revision="$(git -C "$ROOT" show "$commit:Packages/Shared/CmuxGhosttyKit/Package.swift" | python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import ios_notices
print(ios_notices.ghostty_kit_pin(text=sys.stdin.read())["ghostty_revision"])' "$ROOT/scripts/cmux-next/notices")"
[[ "$vt_name" != ghostty && "$vt_revision" == "$pin_revision" ]] || {
  echo "error: the archive holds $vt_name $vt_revision, but the iOS app links GhosttyNextKit of Ghostty $pin_revision" >&2
  exit 1
}
python3 "$ROOT/scripts/cmux-next/notices/ghostty_source_archive.py" verify --archive "${src[0]}" \
  --license-manifest "$dir/ghostty-licenses/SOURCE-MANIFEST.json" \
  --revision "$(git -C "$ROOT" rev-parse "$commit:ghostty")" \
  --next-name "$vt_name" --next-revision "$vt_revision" \
  --next-license-manifest "$dir/$vt_name-licenses/SOURCE-MANIFEST.json"

out="$(mktemp -d)"
cp "${src[0]}" "$out/cmux-ios-source-${build}.tar.gz"
short="${commit:0:11}"
if existing="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/cmux-next-src-$short" --jq .object.sha 2>/dev/null)"; then
  [[ "$existing" == "$commit" ]] || { echo "error: tag cmux-next-src-$short points at $existing, not $commit" >&2; exit 1; }
else
  gh api "repos/$GITHUB_REPOSITORY/git/refs" -f "ref=refs/tags/cmux-next-src-$short" -f "sha=$commit" >/dev/null
fi
if ! gh release view "$RELEASE" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$RELEASE" --repo "$GITHUB_REPOSITORY" --target "$commit" --prerelease --latest=false \
    --title "cmux iOS source archives" \
    --notes "Corresponding source of each cmux iOS release: cmux-ios-source-<build>.tar.gz holds Ghostty and every Ghostty Zig package (z2d included) at the revision that build links. <build> is the build number in the app's version."
fi
python3 "$ROOT/scripts/ci/publish-release-assets.py" --repo "$GITHUB_REPOSITORY" --tag "$RELEASE" \
  --immutable "$out/cmux-ios-source-${build}.tar.gz"
echo "published cmux-ios-source-${build}.tar.gz ($(shasum -a 256 "$out/cmux-ios-source-${build}.tar.gz" | cut -c1-64)) for $commit"
