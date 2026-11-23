# Lumen

![The Lumen look in Dark: the sidebar and tab bar on neutral window glass, the chat on a calm near-solid plane inset in it](screenshots/lumen-dark.png)

![The Lumen look in Light](screenshots/lumen-light.png)

cmux is open all day over your own wallpaper, so Lumen makes the app out of light. The window is
system glass in one neutral tint; the sidebar, tab bar and title area are simply that glass. Your
work sits on a calm, near-solid plane framed by it. Nothing is painted on to look like glass: no
rims, sheens, gradients or glows. Depth is the only hierarchy. It ships Lumen (dark, the default)
and Lumen Light. Version 0.2.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/lumen@feat-cmux-next
cmux settings set appearance.themeFile lumen-light    # lumen (Dark) is the default
cmux setup remove manaflow-ai/lumen-look
```

Remove it and everything you had comes back. It changes no default.

## Three materials

| Material | What is made of it | How Lumen sets it |
| --- | --- | --- |
| Window glass | The window, the sidebar, the tab bar, the title area | `appearance.backgroundBlur: "glass"`, `appearance.background: "none"` (your wallpaper is the art), a neutral tint (`#1b1c1f` dark, `#f4f5f7` light) at `appearance.backgroundOpacity` 0.84 dark, 0.8 light, and `appearance.wallpaperTint: false` so the glass never takes the desktop's colour cast |
| Floating glass | Menus, popovers, toasts, dialogs, the palette | Not settable by a look yet; left as the app draws it |
| Content | The agent chat, terminal, editor, diffs, Markdown, the browser's bar, docks, Settings, internal pages, Home, the New Tab page | `appearance.surfaces.<surface>.color` the same tint, `.opacity` 0.96, no blur of its own |

The sidebar and tab bar set the tint at the window's own fill (0.84 dark, 0.8 light). A surface's
opacity is its fill over the glass in place of the window's, not a second layer on top (an unset
one shows the window's value), so they add no second tone, and the fill under sidebar text is 0.84
dark and 0.8 light: never lower.

Two tone in Lumen is material, not hue: chrome is glass, content is the plane. The selected tab
takes the plane's fill and joins it (`appearance.cornerFlush: "flush"`, no goo);
`appearance.twoTone` is off.

**Chrome style: `card`.** It draws the content as one inset rounded plane on the window, with no
outline on a lone pane and no extra shade. `panes` outlines every pane, which is the extra line
Lumen avoids; `floating` paints a darker shade over the chrome, a second tone on the glass. Lumen
also turns off the sidebar's edge line (`sidebar.border: false`): the change of material is the
edge. A line stays only between two content panes, where both sides are the same material.

## Other settings

- Corners from one rule, inner = outer minus inset: `layout.cornerPadding` 8 and
  `layout.paneCornerRadius` 8 (a 16 pt window corner minus the 8 pt gap), the address field at 8
  (`browser.omnibar.cornerRadius`) with no shadow and no accent in its glass tint
  (`browser.omnibar.glassTint: "none"`).
- A selected row spends one lever, its fill: `appearance.selection: "neutral"`.
  `appearance.accent: "theme"`, `appearance.titleAreaTone: "oneColor"`.
- Sidebar: `sidebar.look: "cmux"`, `sidebar.sectionLook: "quiet"`, standard style.
- The chat keeps the app's own type scale and sizes; tool rows at the normal level of detail
  (`agentPane.display.transcriptView: "normal"`). Density is left as it is.
- `agent-pane/theme.css`: cards at 5% of the text's colour with no outline, the prompt bubble at 14%
  with no edge and 12 px corners, secondary and dim text both at 74% of the text, links the accent
  mixed 85% with the text. Only `cmux.agentPane.style/1` tokens, every colour mixed from the
  theme's own.

## Legibility

Lumen's text is solved on Lumen's own page, not on white. Two sets of numbers follow: what the
tokens compute to, and what the capture in `screenshots/` measures.

Computed, on the content plane at 0.96 over both a pure black and a pure white backdrop, the worse
of the two:

- Body text: 13.8:1 dark, 16.3:1 light. Secondary and dim text (74%): 8.2:1 dark, 7.8:1 light.
  Links: 7.9:1 dark, 6.7:1 light (in light the mix is `#184ba9`).
- The prompt bubble against the page: 1.50:1 dark, 1.35:1 light; text on it 9.1:1 dark, 12.1:1
  light.
- Text on the selection: 8.9:1 dark (`#2c4466`), 14.1:1 light (`#cfdcf5`).
- Terminal colours 1 to 7 and 9 to 15, quiet and neutral, each solved in OKLCH: at least 4.70:1
  dark and 4.71:1 light. Colour 8, the dim gray, at least 3.2:1.

Measured in the capture (the web test window, a solid page):

| | Dark | Light |
| --- | --- | --- |
| Prompt bubble against the page | 1.50:1 | 1.36:1 |
| Tool rows and "Worked for" | 5.91:1 | 4.62:1 |
| Body text | 15.4:1 | 17.8:1 |

Version 0.1 measured 1.16:1 and 1.12:1 for the bubble and 4.10:1 for light tool rows. Version 0.2
raises the bubble's fill from 6% to 14% and darkens Light's text from `#1b1c1f` to `#0c0d0f`.

## What Lumen does not set, and what its capture does not show

- **No capture shows glass.** The screenshots come from the web test window, which draws the window
  as a solid fill. The window material, the wallpaper behind it and the selected tab's join are
  native and have not been captured on a Mac.
- **Tool rows use the app's own muted ink.** The look sets `--cv-text-muted` and `--cv-text-dim`
  to 74%, but the chat reads its own values for tool rows, so that setting does not reach them.
  Their ink is the app's mix of the theme's text and background; Lumen reaches it only through the
  theme's text colour, which is why Light's text is darker in 0.2.
- **These stay under 4.5:1 with Lumen, as they do without it**, because they are the app's: the
  "Waiting for you" pill in Light (3.0:1), the effort word beside the model's name, some syntax
  colours on a diff's added and removed lines (3.7:1 to 4.4:1), and the sidebar's group labels in
  the test window (3.9:1 in Light).
- **The selected sidebar row is blue in the capture** (`#d0dbef` light, `#354259` dark) although
  the look asks for `appearance.selection: "neutral"`: the test window does not read that setting.
- Floating surfaces (menus, popovers, toasts, dialogs), the type scale, density and every size are
  the app's.

## Cannot set yet

- A glass level per role, and a radius for floating panels (menus, popovers, toasts, dialogs)
  apart from the one pane radius.
- Elevation or shadow.
- The composer's paint.
- Menu tokens.
- The tab's shape.
- The type scale.
