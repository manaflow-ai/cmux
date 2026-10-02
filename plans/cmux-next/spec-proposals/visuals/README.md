# Spec proposal: visuals

Design tokens, every component state, and screenshots for cmux-next, so the GPUI and Chromium ports can match the macOS app pixel for pixel and a person can see what each state looks like. Prepared for lawrence-coordinator to commit into manaflow-ai/cmux-next-spec (suggested spec paths in brackets).

| page | contents | spec path |
|---|---|---|
| [design-tokens.md](design-tokens.md) | color model and formulas, resolved colors for 5 themes, type scale, metrics, materials, motion, visual settings | spec/design-tokens.md |
| [design-tokens.json](design-tokens.json) | machine-readable tokens with source path:line for every value; ports import it | spec/design-tokens.json |
| [components/sidebar.md](components/sidebar.md) | workspace rows, badge, status indicator, sections and looks, hover card | spec/visuals/sidebar.md |
| [components/tabs.md](components/tabs.md) | strip, tab, close, +, trailing buttons, unfocused pane styles, hover card, drag | spec/visuals/tabs.md |
| [components/panes.md](components/panes.md) | pane states, focus ring contrast, focus indicator, borders none, dividers, drop overlay | spec/visuals/panes.md |
| [components/palette.md](components/palette.md) | command palette, hover card panel, materials | spec/visuals/palette.md |
| [components/browser.md](components/browser.md) | toolbar, omnibar, buttons | spec/visuals/browser.md |
| [components/agent-pane.md](components/agent-pane.md) | CSS bridge, composer, thread, states | spec/visuals/agent-pane.md |
| [pixel-parity.md](pixel-parity.md) | rules for ports and the screenshot-diff harness plan | spec/pixel-parity.md |
| [images/](images/) | 84 PNGs, 2x crops (window overviews 1x), alt text on every use | spec/images/ |
| [tools/](tools/) | derive_theme_tokens.py (oracle), capture.sh / lib.sh / shot.py / winlist.swift (reproduce the images) | references/visuals-tools/ |

![Default window, dark](images/window/dark-default.png)

Provenance: images from tagged build `specvis-v1` of feat-cmux-next `1824883286a` (fleet job 6ae58467e770db91c783bc05), run with scratch configs (empty Ghostty config, so the default Apple System Colors theme; scratch cmux.json), window never brought to front. Source refs at the same SHA; status indicator refs at `9e5083e7554`. Resolved colors are computed by the Python port and matched screenshot pixels to within one 8-bit level.

## UNVERIFIED states (no screenshot; tokens from code, diagrams where useful)

- Window focused (key): the test window stayed unfocused to avoid taking focus from the user. Code shows no chrome change between key and non-key except the system traffic lights and the terminal cursor.
- Pressed: tab close, new-tab, trailing buttons, browser buttons (a synthetic mouse-down enters AppKit's tracking loop before the capture).
- Hover cards (sidebar and tab): not opened by `debug.mouse action:hover`.
- Status indicator (busy, waiting, error, success, progress): build predates the shared indicator; no socket verb sets agent state.
- Tab drag, sidebar drag lift, drop overlay zones.
- Palette row hover; palette in light appearance (Liquid Glass captured off screen rendered gray; the dark capture also lacks a real backdrop).
- Browser loading progress, find bar, load error page, extension toolbar.
- Agent pane hover, menus, tool-call and permission cards.
- Terminal content colors are Ghostty's and are out of scope here.

## Open questions for Lawrence (via the coordinator)

1. `focus.inactiveTabStyle` and `sidebar.sections.look` are Debug Settings tunables only, with no cmux.json key. Per the "every default is a user setting" rule they need cmux.json keys and docs once a variant is picked. Which variants win (current defaults: fade, quiet)?
2. Should the pixel-parity harness be a CI gate for cmux2-gpui and cmux-browser now, or a report until the ports reach feature parity?
3. Non-macOS fonts: accept the platform system UI font at the same size (proposed), or bundle Inter/SF-like fonts for identical metrics?
