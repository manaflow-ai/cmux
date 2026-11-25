# How {{TITLE}} should look

cmux draws this extension with its own controls, so it matches the app in every theme without a
line of styling. These defaults keep it that way. `src/main.ts` already follows them: change the
words and the data, keep the shape.

## The shape of a view

1. **One lead line.** The one thing a glance should give: a count, a state, the next step. A
   `Text(...).font("headline")`, with its detail under it in `.font("caption").color("secondary")`.
2. **Then the list.** `Row`s, one per thing, each with a `symbol`. A second fact goes in
   `subtitle`, a count or short state in `badge`, never in the title.
3. **Actions last.** One or two `Button`s in an `HStack` with a `Spacer()` between them; more go
   in a `Menu("More", [...])`.
4. **Every state drawn.** Loading (`ProgressView()`), empty (`EmptyState`), failed (`EmptyState`
   with `exclamationmark.triangle` and the error's message). A blank view reads as broken.

Group with `Panel({ title })`: its title is a quiet caption, so make it a noun ("Today", "Start"),
not a sentence. In a Session Info section, skip the Panel: the section header already names it.

## Tones, never colors

Pass a tone, never `#RRGGBB`: a hex color stays the same in every theme, and the app's do not.

| Meaning | Tone |
|---|---|
| Done, passing, connected | `cmux.theme.success` |
| Needs attention, waiting on you | `cmux.theme.warning` |
| Failed, destructive | `cmux.theme.danger` |
| Not started, background detail | `cmux.theme.text.tertiary` |
| Secondary text | `.color("secondary")` |

A `Row`'s `tint` colors its symbol and its badge; tint the rows that mean something and leave
the rest plain. One tinted thing per row at most.

## Sizes come from the kit

Fonts by name: `largeTitle` (a page's title, once), `title2` (a pane's title), `headline` (the
lead line), `body`, `callout`, `caption` (details). No point sizes, no `.padding(n)`,
`.cornerRadius(n)` or `.background(...)` on pieces the kit already spaces: put a group in a
`Panel` instead.

## Symbols

SF Symbol names. These draw everywhere cmux draws an extension (the sidebar, panes, web
panels): `checkmark.circle.fill` (done), `circle` (to do), `clock` (waiting),
`exclamationmark.triangle` (problem), `sparkles` (an agent), `folder`, `doc.text`, `terminal`,
`arrow.triangle.branch`, `arrow.triangle.pull`, `rectangle` (a workspace), `house`, `bell`,
`gearshape`, `magnifyingglass`, `star`, `tray`, `person`, `globe`, `link`, `chart.bar`,
`list.bullet`, `bubble.left`, `arrow.clockwise`, `plus`, `chevron.right` (as a Row's `accessory`
when a tap opens something).

## Words

Short and plain: "3 left today", not "You currently have 3 remaining tasks". Sentence case. A
title says what the thing is; a subtitle says the one fact that tells two rows apart.

## Check it

`cmux ext shot` reloads the extension and prints its scene as an outline with a picture of the
window: look at both before you call it done.
