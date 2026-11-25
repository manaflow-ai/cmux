#!/usr/bin/env bash
# Bump the cmux-cua pin to a release tag, record its unsigned macOS helper asset
# hash, and re-vendor CmuxAgentCursor from the same commit, staged as one change.
#
# Usage: scripts/bump-cmux-cua-pin.sh cmux-cua-vX.Y.Z
#
# Writes in scripts/build-cmux-cua.sh (agreed with the CI lead, 2026-10-04):
#   CMUX_CUA_PINNED_SHA="<the commit the tag points to>"
#   CMUX_CUA_RELEASE_TAG="cmux-cua-vX.Y.Z"
#   CMUX_CUA_DARWIN_UNIVERSAL_UNSIGNED_SHA256="<sha256 of cmux-cua-X.Y.Z-darwin-universal-unsigned.tar.gz>"
# The hash is computed from the downloaded asset and must equal the release's
# checksums.txt (or SHA256SUMS) line. nightly-next and release builds embed the helper from that
# asset and fail on a mismatch. Build the app on the fleet before pushing.
set -euo pipefail
tag="${1:-}"
[[ "$tag" =~ ^cmux-cua-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "usage: $0 cmux-cua-vX.Y.Z" >&2; exit 2; }
version="${BASH_REMATCH[1]}"
repo="manaflow-ai/cmux-cua"
root="$(cd "$(dirname "$0")/.." && pwd)"
pin_file="$root/scripts/build-cmux-cua.sh"

# The commit the tag points to (peeled for annotated tags).
sha="$(git ls-remote "https://github.com/$repo.git" "refs/tags/$tag^{}" | awk '{print $1}')"
[[ -n "$sha" ]] || sha="$(git ls-remote "https://github.com/$repo.git" "refs/tags/$tag" | awk '{print $1}')"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "tag $tag not found in $repo" >&2; exit 1; }

asset="cmux-cua-$version-darwin-universal-unsigned.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The release's checksum list: checksums.txt (current workflow) or SHA256SUMS.
assets="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')"
sums=""
for candidate in checksums.txt SHA256SUMS; do
  if grep -qx "$candidate" <<<"$assets"; then sums="$candidate"; break; fi
done
[[ -n "$sums" ]] || { echo "release $tag has no checksums.txt or SHA256SUMS" >&2; exit 1; }
grep -qx "$asset" <<<"$assets" || { echo "release $tag lacks $asset" >&2; exit 1; }
gh release download "$tag" --repo "$repo" --pattern "$asset" --pattern "$sums" --dir "$work"
digest="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
listed="$(awk -v name="$asset" '{ f = $2; sub(/^\*/, "", f); if (f == name) print $1 }' "$work/$sums")"
[[ "$digest" == "$listed" ]] || { echo "$asset: computed $digest, $sums says '${listed:-missing}'" >&2; exit 1; }

python3 - "$pin_file" "$sha" "$tag" "$digest" <<'PY'
import re, sys
path, sha, tag, digest = sys.argv[1:]
text = open(path).read()
pin = re.compile(r'^CMUX_CUA_PINNED_SHA="[0-9a-f]{40}"$', re.M)
if not pin.search(text):
    sys.exit("CMUX_CUA_PINNED_SHA line not found")
text = re.sub(r'^CMUX_CUA_RELEASE_TAG=.*\n', '', text, flags=re.M)
text = re.sub(r'^CMUX_CUA_DARWIN_UNIVERSAL_UNSIGNED_SHA256=.*\n', '', text, flags=re.M)
text = pin.sub(f'CMUX_CUA_PINNED_SHA="{sha}"\nCMUX_CUA_RELEASE_TAG="{tag}"\n'
               f'CMUX_CUA_DARWIN_UNIVERSAL_UNSIGNED_SHA256="{digest}"', text, count=1)
open(path, "w").write(text)
PY
python3 "$root/scripts/cmux_agent_cursor_vendor.py" sync
python3 "$root/scripts/cmux_agent_cursor_vendor.py" check
git -C "$root" add scripts/build-cmux-cua.sh Packages/Shared/CmuxAgentCursor
echo "staged: pin $sha ($tag), $asset sha256 $digest, vendored CmuxAgentCursor; commit them together"
