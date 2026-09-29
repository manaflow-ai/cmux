#!/usr/bin/env bash
# Rewrites <app>/Contents/Resources/bin/cmux-tui.version after a release job
# replaced the arm64 client the Xcode "Bundle cmux-tui" phase bundled with the
# universal client from the pinned commit's attested manifest
# (scripts/install-cmux-tui-client.sh). Same keys as bundle-cmux-tui.sh.
#
# Usage: write-cmux-tui-version.sh <app> <commit>
set -euo pipefail
app="${1:?usage: write-cmux-tui-version.sh <app> <commit>}"
commit="${2:?usage: write-cmux-tui-version.sh <app> <commit>}"
bin="$app/Contents/Resources/bin/cmux-tui"
[[ -x "$bin" ]] || { echo "error: $bin is missing" >&2; exit 1; }
version_line="$("$bin" --version 2>/dev/null | head -n 1 || true)"
[[ "$version_line" == *"$commit"* ]] || {
  echo "error: $bin reports '$version_line', not commit $commit" >&2
  exit 1
}
{
  printf 'commit=%s\n' "$commit"
  printf 'source=release-manifest\n'
  printf 'sha256=%s\n' "$(shasum -a 256 "$bin" | awk '{print $1}')"
  printf 'run=\n'
  printf 'url=https://files.cmux.com/cmux-tui/%s/manifest.json\n' "$commit"
  printf 'version=%s\n' "$version_line"
} > "$bin.version"
echo "cmux-tui.version: $commit ($(lipo -archs "$bin"))"
