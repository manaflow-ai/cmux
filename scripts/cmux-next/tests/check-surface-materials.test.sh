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

reset; manifest '' ''
printf '<BaseMenu.Popup\n  // a comment with an apostrophe: Base UI'"'"'s popup\n  className={cx(\n    "ui-popup ui-glass ui-menu",\n    className,\n  )}\n>\n' > "$web/Multi.tsx"
expect_fail multiline-class web-floating

reset; manifest '' ''
printf '<div className="ui-popup ui-glass one" data-host-glass="menu">\n</div>\n<div className="ui-popup ui-glass two">\n</div>\n' > "$web/Siblings.tsx"
expect_fail marked-sibling-does-not-exempt web-floating

reset; manifest '' ''
printf '<div className="ui-popup ui-glass" data-host-glass-cover="">\n</div>\n' > "$web/Cover.tsx"
expect_fail cover-alone-is-not-a-mark web-floating

reset; manifest '' ''
printf 'const popupClassName = cx("ui-popup ui-glass ui-popover", className);\nreturn <BasePopover.Popup className={popupClassName}>x</BasePopover.Popup>;\n' > "$web/Named.tsx"
expect_fail class-in-a-const web-floating

printf 'const popupClassName = cx("ui-popup ui-glass ui-popover", className);\nreturn <BasePopover.Popup className={popupClassName} data-host-glass="popover">x</BasePopover.Popup>;\n' > "$web/Named.tsx"
expect_pass class-in-a-const-marked

reset; manifest '' ''
printf '<div className="ui-popup ui-glass" children={<span data-host-glass="menu" />} />\n' > "$web/Nested.tsx"
expect_fail nested-mark-is-not-the-elements web-floating

printf '<div className="ui-popup ui-glass" title="data-host-glass=menu" />\n' > "$web/Nested.tsx"
expect_fail mark-in-a-string-is-not-a-mark web-floating

reset; manifest '' ''
printf 'const Popup = () => <div className="ui-popup ui-glass" data-host-glass="menu" />;\nreturn <Popup />;\n' > "$web/Component.tsx"
expect_pass component-const-is-not-a-class

reset; manifest '' ''
printf '<div children={<div className="ui-popup ui-glass" data-host-glass="menu" />} />\n' > "$web/Outer.tsx"
expect_pass a-child-popup-is-not-the-outer-element

reset; manifest '' ''
printf 'const popupClassName = "ui-popup ui-glass";\nreturn <div className={cx({ active: isActive }, popupClassName)} />;\n' > "$web/ObjectArg.tsx"
expect_fail const-after-an-object-argument web-floating

reset; manifest '' ''
printf '<div className={cx(/* } */ "ui-popup ui-glass")} />\n' > "$web/Comment.tsx"
expect_fail brace-in-a-comment web-floating

reset; manifest '' ''
printf '<div className = "ui-popup ui-glass" />\n' > "$web/Spaced.tsx"
expect_fail spaces-around-the-equals web-floating

reset; manifest '' ''
printf 'const popup = "ui-popup ui-glass";\nreturn <div className="popup" />;\n' > "$web/Literal.tsx"
expect_pass a-const-name-in-a-string-is-not-a-reference

reset; manifest '' ''
printf 'const popup = "ui-popup ui-glass";\nreturn <div className={cx(/* don'"'"'t */ "a", popup, /* it'"'"'s */)} />;\n' > "$web/Apostrophe.tsx"
expect_fail an-apostrophe-in-a-comment-hides-no-const web-floating

reset; manifest '' ''
printf '<div className={cx(/* ui-popup ui-glass */ "a")} />\n' > "$web/CommentClass.tsx"
expect_pass classes-in-a-comment-are-not-classes

reset; manifest '' ''
printf 'const popup = "ui-popup ui-glass";\nreturn <div className={`popup x`} />;\n' > "$web/Template.tsx"
expect_pass a-const-name-in-a-template-is-not-a-reference

reset; manifest '' ''
printf 'const popup = "ui-popup ui-glass";\nreturn <div className={`x ${popup}`} />;\n' > "$web/Interpolated.tsx"
expect_fail a-const-in-a-template-interpolation web-floating

reset; manifest '' ''
printf 'const popup = "ui-popup ui-glass";\nreturn <div className = {popup} />;\n' > "$web/SpacedBrace.tsx"
expect_fail spaces-around-a-braced-equals web-floating

reset; manifest '' ''
printf '<div className={cx("https://x//y", "ui-popup ui-glass")} />\n' > "$web/Url.tsx"
expect_fail slashes-in-a-string-are-not-a-comment web-floating

echo "check-surface-materials.test: ok"
