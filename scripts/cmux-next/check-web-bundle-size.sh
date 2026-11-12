#!/usr/bin/env bash
# Apply the nightly component caps to generated resources before a native build.
# Usage: check-web-bundle-size.sh [source-or-output-root] [budget.json]
set -euo pipefail
tools_dir="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$tools_dir/../..}"
budget="${2:-$tools_dir/bundle-size-budget.json}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
resources="$stage/web.app/Contents/Resources"
mkdir -p "$resources"
for module in CmuxNextPages CmuxNextAgentPane; do
  case "$module" in
    CmuxNextPages) leaf=pages; entry=settings/index.html ;;
    *) leaf=agent-pane; entry=index.html ;;
  esac
  source="$root/Packages/macOS/CmuxNext/Sources/$module/Resources/$leaf"
  if [[ ! -s "$source/$entry" ]]; then
    echo "bundle-size: missing generated $source/$entry" >&2
    echo "next: run scripts/cmux-next/build-web-bundles.sh" >&2
    exit 1
  fi
  destination="$resources/CmuxNext_${module}.bundle/Contents/Resources/$leaf"
  mkdir -p "$destination"
  cp -R "$source/." "$destination/"
done
# This is a resource-only app: retain forbidden paths and the two component caps,
# without claiming to check native binaries, whole-app size or a signed DMG.
jq -e '
  .variants.arm64 as $v | .web_resource_metadata_reserve_bytes as $reserve |
  ["Contents/Resources/CmuxNext_CmuxNextPages.bundle",
   "Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle"] as $paths |
  if all($paths[]; . as $p | ($v.components[$p] | type) == "number"
      and ($reserve[$p] | type) == "number" and $reserve[$p] >= 0
      and $v.components[$p] > $reserve[$p]) then
    {schema: 1, variants: {arm64: {
      forbidden: $v.forbidden,
      components: ($v.components | with_entries(select(.key as $k | $paths | index($k)))
                   | with_entries(.value -= $reserve[.key]))
    }}}
  else error("missing or invalid Pages/AgentPane component cap or metadata reserve") end
' "$budget" > "$stage/budget.json"
python3 -I "$tools_dir/bundle-size.py" report "$stage/web.app"
python3 -I "$tools_dir/bundle-size.py" check "$stage/web.app" --budget "$stage/budget.json" --variant arm64
