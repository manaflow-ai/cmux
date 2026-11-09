#!/usr/bin/env bash
# check-surface-materials.py: a native file that builds glass with no kind, a sidebar card on real
# glass, a stale entry, and a floating web glass surface in the agent pane without host glass fail; a
# listed file, a marked surface, a `host-glass-allow:` reason and a pending entry pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-surface-materials.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-surface-materials.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
src="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextDemo"
web="$tmp/webviews/src/ui"
mkdir -p "$src" "$web" "$tmp/schemas/surface-materials"

manifest() {
  cat > "$tmp/schemas/surface-materials/surface-materials.json" <<JSON
{"kinds": {"native-overlay": {"render": "native", "materials": ["real-glass"]},
           "sidebar-card": {"render": "native", "materials": ["card-veil"]},
           "web-floating": {"render": "web", "materials": ["host-glass", "page-glass"]}},
 "native": {$1}, "web_floating_pending": {$2}}
JSON
}

run() { python3 -I "$CHECK" "$tmp"; }
expect_fail() {
  local name="$1" rule="$2"
  if out="$(run)"; then echo "check-surface-materials.test: $name passed, expected [$rule]"; echo "$out"; exit 1; fi
  grep -q "\[$rule\]" <<<"$out" || { echo "check-surface-materials.test: $name did not name [$rule]"; echo "$out"; exit 1; }
}
expect_pass() {
  local name="$1"
  out="$(run)" || { echo "check-surface-materials.test: $name failed"; echo "$out"; exit 1; }
}
reset() { rm -f "$src"/*.swift "$web"/*.tsx; }

reset; manifest '' ''
printf '        let panel = Glass.makeOverlayPanel(content: body)\n' > "$src/Hud.swift"
expect_fail unlisted native-unlisted

manifest '"CmuxNextDemo/Hud.swift": "native-overlay"' ''
expect_pass listed

printf '        // Glass.makeOverlayPanel(content: body) is what the card does not use\n' > "$src/Hud.swift"
expect_fail stale native-stale

reset; manifest '"CmuxNextDemo/Card.swift": "sidebar-card"' ''
printf '        let glass = GlassPanelView(frame: .zero)\n' > "$src/Card.swift"
expect_fail card-on-glass native-material

printf '        let card = CardSurfaceView(cornerRadius: 10)\n' > "$src/Card.swift"
expect_pass card-veil

manifest '"CmuxNextDemo/Card.swift": "web-floating"' ''
expect_fail web-kind native-kind

reset; manifest '' ''
printf '<BasePopover.Popup\n  className="ui-popup ui-glass tip"\n>\n' > "$web/Tip.tsx"
expect_fail unmarked web-floating

printf '<BasePopover.Popup\n  className="ui-popup ui-glass tip"\n  data-host-glass="popover"\n>\n' > "$web/Tip.tsx"
expect_pass marked

printf '<BasePopover.Popup\n  // host-glass-allow: sits over the composer, which no filter may blur\n  className="ui-popup ui-glass tip"\n>\n' > "$web/Tip.tsx"
expect_pass allowed

printf '<BasePopover.Popup\n  className="ui-popup ui-glass tip"\n>\n' > "$web/Tip.tsx"
manifest '' '"ui/Tip.tsx": "backlog"'
expect_pass pending

printf '<BasePopover.Popup\n  className="ui-popup ui-glass tip"\n  data-host-glass="popover"\n>\n' > "$web/Tip.tsx"
expect_fail pending-stale web-floating

echo "check-surface-materials.test: ok"
