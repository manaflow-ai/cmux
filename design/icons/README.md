# cmux-next icon set and registry

One set of semantic icon names for the native app and the agent pane, drawn once and rendered by both.

## Layout
- `source/*.json`: the drawings. Each entry has a dotted `name` (`agent.chat`, `pane.split.right`,
  `status.running`), its `meaning`, Line, Solid and optional Cat SVG, design alternates (`alts`), and
  the SF Symbols it `replaces`. Drawing rules are in [SPEC.md](SPEC.md).
- `tools/`: the measurement scripts behind the size rules (ink bounding box, coverage, row metrics,
  optical centering and coverage trim). They run headless Chrome and only matter when drawings change.
- `scripts/icons/build_pack.py`: flattens the sources into the pack both renderers draw. Run it after
  editing a source; `--check` fails when an output is stale.

Generated outputs (do not edit):
- `Packages/macOS/CmuxNext/Sources/CmuxNextIcons/Resources/cmux-icons.json` and `icon-catalog.json`
- `Packages/macOS/CmuxNext/Sources/CmuxNextIcons/IconName+Members.swift` and `IconName+Catalog.swift`
- `webviews/src/agent-session/acpmux/icons/cmuxIcons.json`

## Pack format
```json
{"id": "cmux", "version": 1, "grid": 24,
 "icons": {"agent.chat": {"line": [Layer], "solid": [Layer], "cat": [Layer]}}}
```
A layer is `{d, op, w?, alpha?, dash?, dashPhase?, cap?, join?, accent?}`:
- `d` uses only absolute `M`, `L`, `C` and `Z`. Arcs, rects, circles and transforms are resolved at
  build time, so neither renderer needs an SVG engine.
- `op` is `stroke`, `fill`, `clearFill` or `clearStroke`. Clear layers come from SVG masks and erase
  only what was drawn before them.
- `accent` layers draw in the accent color. Only `cat` drawings have them.
- `cat` is a full drawing, not an overlay, because some Cat icons change the base shape.

## Catalog
`icon-catalog.json` lists every name with its meaning, family and an SF Symbol fallback. Names in one
family (`disclosure.collapsed` and `disclosure.expanded`) draw at one size per surface. Status, state
and dot names carry `denseStyle: solid`: below 13 pt they draw Solid, since 1.5 strokes go faint.

## Sizes
- Floor 12 pt everywhere.
- In rows the icon is round(1.2 x label size): 16 at 13 pt text, 13 at 11 pt. The slot is the icon box
  (viewBox cropped to `2.5 2.5 19 19`, overflow visible), the gap is one token per density (8 regular,
  6 compact), and the icon centers on the label's cap-height middle. No chip behind it; hover and
  selection tint the whole row.

## Renderers
- Native: `CmuxNextIcons`. `Icon(.agentChat)` (SwiftUI), `NSImage.icon(_:size:style:)` (template image
  for AppKit), and a resolver that falls back from the pack to the catalog's SF Symbol.
- Web: `webviews/src/agent-session/acpmux/icons`. `<Icon name="agent.chat" />`, with clear layers
  rendered as masks.

## Rollout
1. This registry and the assets. No call site uses them yet.
2. Migrations, one surface per PR: agent pane, sidebar, tab strip, pane chrome, composer, transcript,
   permission and trust cards, diff, settings, Cloud, browser chrome, palette, onboarding. Each PR
   removes that surface's ad hoc icon sizes and hand-drawn SVGs.
3. A pack setting (`cmux` or `system`) and the Cat accent setting.
