# Chat surfaces: one set of levels

Lawrence, 2026-11-19, a see-through chat over a wallpaper: the "Edited PROPOSAL.md" card nearly
clear with a faint ring, the "rate limited" error card under it a darker frosted box, the edit card's
icon tile a dark hole and the two cards' outlined buttons on two other rings:

> bgs are different, we need to make all bgs concsistent, from first principles

## What a chat surface sits on

The chat page is the ground. In an opaque window it is the theme's page colour; in a see-through
window, or with a custom pane background, it is clear and the window's glass, wallpaper or picture
shows through (`AgentPaneTheme.pageColor`). So a surface in the chat never knows what is under it.

A fill that holds over any ground is one that is relative to it: the page's **ink** (its text colour)
laid over clear at a small share. Over any backdrop it moves the colour the same fraction toward the
ink, so its step against what is under it is the same over an opaque page, glass, a dark or a light
wallpaper. It flips with light and dark on its own (dark ink on a light theme, light ink on a dark
one), it keeps the art visible, and the text on it keeps the contrast it has on the page beside it.
That is also how the native chrome draws its hover, pressed and selection fills (`ThemeTokens`:
the foreground at 4 to 14%), so the chat and the chrome agree.

Fills that break this, and were in the chat:
- **the page colour** (`--agent-page-bg`): a solid box in an opaque window, nothing at all in a
  see-through one (the edit card);
- **the page colour mixed with black**: a dark hole over a picture (the edit card's tile);
- **glass** (a veil of the theme surface and a backdrop blur): right for what floats over content,
  wrong for content itself, which `surface-materials.md` keeps clear (the error card).

## The levels

`schemas/design-scale/design-scale.json` `surfaces`, written by `gen-design-scale.mjs` into
`desktop.css` as `--ds-surface-*`. `--ds-surface-ink` is the ink (the agent pane: `--agent-text`).

| Level | Fill | Line | Rank |
|---|---|---|---|
| page | none | none | the transcript's ground: messages, rows, prose |
| card | ink 4% | ink 10% | a container of content: tool, edit, error, permission and subagent cards, plans, code blocks, tool output |
| inset | ink 8% | none | a piece in a card or in text: an icon tile, inline code, a chip, a key cap |
| hover | ink 6% | none | a control in the page under the pointer |
| control | none | ink 16% | a secondary button's outline at rest |

- Nesting adds the step again: an inset tile on a card is ink 8% over ink 4%, so its step to its parent
  is the same as the card's step to the page.
- States: a control in the page hovers at the hover level (`--ds-surface-hover`, ink 6%), half way from
  clear to the press; pressed is `--ds-color-pressed` and selection (an on toggle, a checked segment)
  `--ds-color-selection`, the host's own fills. The host's chrome hover (`--ds-color-hover`, ink 4% in a
  light theme) is for chrome on its own material: in the page, over glass or a picture, it read ΔL* 2 to
  3 on a fleet Mac (2026-11-19), so Undo and View changes all but lost their hover in light. A primary button is the accent or the transient
  action fill: a role, not a surface.
- A state over a filled rest is a layer, never a swap: a control that rests on a level (a filled
  button on inset, a row on card) takes `background-image: var(--ds-surface-hover-layer)` (or
  `-pressed-layer`) over its own fill. Swapped in, a hover (ink 4 to 6%) is lighter than an inset rest
  (8%), so the pointer would lighten the button. `statesReplacingFilledRest()` in the check
  fails on a swap.
- Lines are 1 px ink 10% for a card (an inner divider too), ink 16% for a control. appearance.borders
  none clears them; Increase Contrast draws them in the ink itself.
- Radius: a card is `--grid-cards-radius` (12), code blocks included (they were 16); controls are
  `--ds-radius-control`.
- Floating surfaces (menus, popovers, hover cards, tooltips, dialogs) stay glass at their glass levels
  (`glass.css`, `transient-material.md`), and the composer and docked bars stay at the popover and chrome
  levels: they float over the transcript, so they frost what is under them. The levels here are for what
  sits in the page.

## Audit (feat-cmux-next 766fd86)

`W/` is `webviews/src/agent-session/acpmux/`. Over a see-through window the page is clear; over an
opaque one it is the theme's page colour.

| Surface | Before: fill / line / radius | Source | After |
|---|---|---|---|
| Edit card | page colour, head ink 3% / theme separator / 12 | `W/styles.css` `.acpmux-edited`, `W/conversation/EditedFilesCard.css` | card |
| Edit card tile | page colour mixed with black (68% dark, 94% light) / none / 8 | `EditedFilesCard.css` | inset |
| Turn error card | glass: theme surface at 42/55% + 32 px frost / glass rim / 12 | `W/conversation/TurnRows.tsx` (`ui-glass ui-transient-error`), `conversation.css` | card |
| "View changes", "Set up cmux CodeRouter" | none / theme separator, accent 34% / control | `.acpmux-review-changes`, `.cv-turn-auth-action` | control |
| Tool cards: shell, output, MCP call, fields, tool error, run elsewhere, shell block | ink 4% / ink 10% / 12, 8, 6 | `conversation.css` (`--cv-card-fill`, `--cv-card-ring`) | card (unchanged values) |
| Permission ask | ink 4% / ink 10% hairline / 8 | `.acpmux-ask` | card |
| Plan list | ink 4% / ink 10% / 12 | `.cv-plan` | card |
| Code block | ink 7.5% / ink 11.5% / 16 | `.cv-codeblock` | card, radius 12 |
| Inline code | ink 11% / none / 5 | `--cv-code-bg` | inset |
| Subagent card | ink 6% / accent 22% hairline + white 5% top line / 12 | `W/subagents/AgentCard.css` | card |
| Rows, chips, keycaps, pills at rest (52 files) | ink 3 to 12%, one share each | many | card (<= 5%) or inset (6 to 12%) |
| Hovers and presses (52 files) | ink 4 to 12%, one share each | many | the hover level; pressed; an on toggle selection |
| User bubble | glass tint ink 14% | `.cv-user__bubble` | unchanged: the prompt keeps stronger glass (`messageSurfaces.test.ts`) |
| Composer, queue, trust ask, dictation notice | composer tokens (`--acpmux-composer-*`) over the popover glass level | `W/styles.css`, `composerStates.css` | unchanged: docked glass |
| Menus, popovers, pickers, hover cards, tooltips | the menu or chip glass level; on the App's glass, host glass | `ui/glass/glass.css` | unchanged |
| Media scrims, diff marks, role tints (accent, status, ANSI), opaque menu mixes | their own | many | backlog (below) |

## The check

`webviews/scripts/check-chat-surfaces.ts` finds a raw fill in the chat's stylesheets: a background, or a
`--*-bg`, `--*-fill` or `--*-surface` property, written as a colour of its own (a literal or a
`color-mix()` on the spot). `webviews/test/chat-surfaces.test.ts` fails on a new one, and pins every
card above to the card level and its line. The fills that predate the levels (278 in 68 files: role
tints, media scrims, opaque menu and composer mixes) are a per-file backlog in
`test/chat-surfaces.baseline.json` that only shrinks: a file may hold no more than its count, and must
lower it when it holds fewer. A fill that truly is a colour of its own says why on its line:
`/* chat-surface-allow: <reason> */`.
