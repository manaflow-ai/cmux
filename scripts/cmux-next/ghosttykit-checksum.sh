#!/usr/bin/env bash
# Pins scripts/ghosttykit-checksums.txt for the ghostty gitlink of REPO's HEAD,
# from our own published GhosttyKit release only (manaflow-ai/ghostty, the tag
# download-prebuilt-ghosttykit.sh --print-release names): it downloads the
# release archive, hashes it, checks the hash against the digest GitHub records
# for that asset, and appends "<ghostty sha> <sha256>". Never from a local build.
# cmux-next-base-autofix.yml commits the line; when the release is missing it
# dispatches build-ghosttykit.yml and runs this again after the publish.
#
# Prints "ok: ..." when the line is already there, "fixed: ..." when it added
# it. Exits 3 when no release exists yet for that commit.
#
# Usage: scripts/cmux-next/ghosttykit-checksum.sh REPO  (needs gh with GH_TOKEN)
set -euo pipefail
repo="$(cd "${1:?usage: $0 REPO}" && pwd)"
checksums="$repo/scripts/ghosttykit-checksums.txt"

sha="$(git -C "$repo" ls-tree HEAD ghostty | awk '$2 == "commit" { print $3 }')"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: HEAD has no ghostty gitlink" >&2; exit 1; }
if awk -v sha="$sha" '$1 == sha { found = 1 } END { exit !found }' "$checksums"; then
  echo "ok: GhosttyKit checksum for ghostty $sha is pinned"
  exit 0
fi

read -r tag archive < <(GHOSTTY_SHA="$sha" "$repo/scripts/download-prebuilt-ghosttykit.sh" --print-release)
# gh api prints an error body on stdout; only a 404 means "not published yet".
if ! release="$(gh api "repos/manaflow-ai/ghostty/releases/tags/$tag" 2>/dev/null)"; then
  if [[ "$(jq -r '.status // empty' <<<"$release" 2>/dev/null)" == 404 ]]; then
    echo "missing: no GhosttyKit release $tag for ghostty $sha"
    exit 3
  fi
  echo "error: could not read release $tag: $release" >&2
  exit 1
fi
digest="$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .digest // "none"' <<<"$release")"
if [[ -z "$digest" ]]; then
  echo "missing: release $tag has no $archive yet (ghostty $sha)"
  exit 3
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ghosttykit-checksum.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" --repo manaflow-ai/ghostty --pattern "$archive" --dir "$tmp"
sum="$(sha256sum "$tmp/$archive" | awk '{ print $1 }')"
if [[ "$digest" != none && "$digest" != "sha256:$sum" ]]; then
  echo "error: $tag/$archive hashes to $sum, but GitHub records $digest" >&2
  exit 1
fi
echo "$sha $sum" >> "$checksums"
echo "fixed: pinned GhosttyKit checksum for ghostty $sha from release $tag"
