#!/usr/bin/env bash
# Rewrites <app>/Contents/Resources/bin/cmux-tui.version after a release or
# nightly job replaced the arm64 client the Xcode "Bundle cmux-tui" phase
# bundled with a universal client from an attested commit manifest
# (scripts/install-cmux-tui-client.sh). Same keys as bundle-cmux-tui.sh.
# A release passes the pinned commit (mode=pin); nightly passes the commit
# that published its tree and the tree key (mode=tree).
#
# Usage: write-cmux-tui-version.sh <app> <commit> [<tree-key>]
set -euo pipefail
app="${1:?usage: write-cmux-tui-version.sh <app> <commit>}"
commit="${2:?usage: write-cmux-tui-version.sh <app> <commit>}"
key="${3:-}"
bin="$app/Contents/Resources/bin/cmux-tui"
[[ -x "$bin" ]] || { echo "error: $bin is missing" >&2; exit 1; }
version_line="$("$bin" --version 2>/dev/null | head -n 1 || true)"
[[ "$version_line" == *"$commit"* ]] || {
  echo "error: $bin reports '$version_line', not commit $commit" >&2
  exit 1
}
{
  if [[ -n "$key" ]]; then printf 'mode=tree\n'; else printf 'mode=pin\n'; fi
  printf 'key=%s\n' "$key"
  printf 'commit=%s\n' "$commit"
  printf 'source=release-manifest\n'
  printf 'sha256=%s\n' "$(shasum -a 256 "$bin" | awk '{print $1}')"
  printf 'run=\n'
  printf 'url=https://files.cmux.com/cmux-tui/%s/manifest.json\n' "$commit"
  printf 'version=%s\n' "$version_line"
} > "$bin.version"
echo "cmux-tui.version: $commit${key:+ (tree $key)} ($(lipo -archs "$bin"))"
