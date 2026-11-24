# Extension design: a view that passes the design check

Read this page before you write a widget, a sidebar section or a pane. Every view an
extension draws goes through the design check. It checks type sizes, spacing, colors,
contrast and line limits. `cmux ext dev` and `cmux ext shot` print each warning with its fix
and still load the view. Registry review refuses a listing that has any warning. The
cmux-extension-sdk helpers below already pass the check, so build from them and leave raw
sizes, raw gaps and hex colors out.

## The loop

1. Write `src/main.ts` from the helpers on this page. To start from a working widget, run
   `cmux ext new NAME --kind widget --json`.
2. Run `cmux ext shot --json`. It loads the folder into the running cmux (as
   `cmux ext dev --once` does) and takes a picture. Read three things from its output:
   - `ok` and `errors`: did it build and render?
   - `design`: the list of design warnings. Each one has `check`, `message`, `fix` and the
     `node` it is about.
   - `shot.path`: the picture.
3. Fix every entry in `design`, using its `fix` and the table below, then run step 2 again.
   You are done only when `design` is `[]`. A warning is never fine to leave, and leaving
   one means the registry refuses the listing.
4. Look at the picture next to the gallery's reference widgets. In a cmux checkout, run
   `bun run gallery:dev` in `webviews/`, then open
   `/gallery/#/apps.design-check` (the "after" column) and `/gallery/#/apps.design-system`.
   Without a checkout, compare against the example widget below. Each tile should show one
   value, one title line and one or two quiet lines, aligned on a single leading edge.
5. To list the extension, run `cmux ext shot --record`. It writes the scene it rendered into
   `preview/scenes.json`; run it once for each size the widget offers (change the size in
   Edit Widgets). Add `"preview/"` to the manifest's `files`. Then run `cmux ext publish --json`.
   Its `design` step is the check registry review runs, and
   `cmux ext design --listing DIR --json` runs that same check by itself.

To check a scene file outside the running app, use `cmux ext design FILE... --widget --json`.
It exits 1 when there is a warning.

## Type roles

Text goes through a role, not a point size. Each helper draws one role at its size and
weight, and limits the text to one line unless you pass `{ lines: 2 }`.

| Role | Size, weight | Helper | Use it for |
|---|---|---|---|
| numeral | 34 semibold | `BigNumber(text)` | The one glanceable value: a time, a count, a temperature |
| heading | 20 semibold | `Heading(text)`, `BigNumber(text, { role: "heading" })` | A word when there is no number: a place, a status |
| title | 15 semibold | `Headline(text)` | A line under or beside the value |
| label | 13 semibold | `Label(text)`, `WidgetTitle(text, { symbol })` | The tile's name, a row's title |
| body | 13 regular | `Body(text)` | A sentence |
| caption | 12 regular | `Caption(text)` | Detail: a date, a "3 left" |
| footnote | 11 regular | `Footnote(text)` | The least important line: "updated 9:41" |

`TextIn(role, text, { lines })` draws any of these by name, as in `TextIn("caption", "Today")`.
A widget uses at most four roles. A good set is numeral + label + body + caption.

Never write `Text(...).font(14)`, a font name such as `.font("title")` or `.font("largeTitle")`
(the web and macOS draw those at different sizes), or a `Text` with no line limit inside a
widget.

## Spacing: SPACE

Every `spacing`, `padding`, `paddingHorizontal` and `paddingVertical` is a step on this
scale, in points:

| Key | none | hairline | xxs | xs | s | m | l | xl | xxl | xxxl | huge |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Points | 0 | 2 | 4 | 6 | 8 | 12 | 16 | 20 | 24 | 32 | 48 |

Write `VStack({ spacing: SPACE.s, alignment: "leading" }, [...])` and `.padding(SPACE.m)`
with keys, not numbers. `WidgetFrame` already pads the tile (16 points on the New Tab page,
12 in the sidebar), so add no padding of your own around it.

## Color roles

A color is a role: `primary`, `secondary`, `tertiary`, `accent`, `success`, `warning`,
`danger` or `separator`. Roles follow the theme and keep contrast in light and dark. A hex
color such as `#ff0000` or a CSS name such as `"blue"` gets a warning.

`accent`, `success`, `warning` and `danger` count as accents, and a view uses at most two.
Use `accent` for the one thing to look at and `secondary` for the rest. Keep `success`,
`warning` and `danger` for state (done, low, failed).

`WidgetTitle` is tinted `accent` by default, so it uses one of the two. A view that shows
two states at once (a passed build in `success` next to a failed one in `danger`) has no
accent left for the title: write `WidgetTitle("CI", { symbol: "hammer", tint: "secondary" })`.

## Components

The widget helpers, all exported by `cmux-extension-sdk`:

| Helper | What it draws |
|---|---|
| `widget((ctx) => View)` | The export the manifest names for `cmux.widget/1`. `ctx` has `size` (`small`, `medium`, `large`), `place` (`newtab`, `sidebar`), `now()` (the clock in Unix milliseconds, a number: `new Date(ctx.now()).getHours()`; there is no `Intl`), `settings`, and `preview` (true in the Add Widget gallery: show sample data and write nothing) |
| `WidgetFrame([...], { place: ctx.place })` | The tile: a leading-aligned column with the standard inset. Put a `Spacer()` in it to push the value to the bottom |
| `WidgetTitle("Name", { symbol: "clock" })` | The header: an SF Symbol and a short name, in `accent` |
| `BigNumber(() => value)` | The value. Its digits roll when it changes |
| `bySize(ctx, { small: () => ..., medium: () => ..., large: () => ... })` | A different view for each size. `medium` falls back to `small` |
| `RowList(() => items, { max: 3 })` | A list for medium and large tiles. Each item is `{ id, title, detail?, trailing?, tint?, symbol?, done? }` |
| `Gauge(() => 0.4, { label: "40%" })` | A progress bar with a caption |
| `WidgetSymbol("sun.max", { tint: "warning" })` | A symbol at label size |
| `WidgetEmpty("No events", { message: "Free all day", symbol: "calendar" })` | The empty state: what the tile shows with no data |
| `Timeline({ ... })` | A day's events as bars by hour |

`HStack`, `VStack`, `Spacer`, `Divider` and `ForEach` are exported for layout as well.
Write every `Text` through a role helper instead.

## A widget that passes

`src/main.ts`:

```ts
import { BigNumber, bySize, Caption, Label, RowList, SPACE, Spacer, VStack, widget, WidgetEmpty, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

type Task = { id: string; title: string; due: string }
const SAMPLE: Task[] = [
  { id: "1", title: "Review the PR", due: "10:00" },
  { id: "2", title: "Write the notes", due: "14:30" },
  { id: "3", title: "Ship it", due: "17:00" },
]

export const renderWidget = widget((ctx) => {
  const tasks = SAMPLE
  if (tasks.length === 0) return WidgetFrame([WidgetEmpty("Nothing due", { message: "Enjoy the day", symbol: "checkmark.circle" })], { place: ctx.place })
  return WidgetFrame(
    [
      WidgetTitle("Today", { symbol: "checklist" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            BigNumber(String(tasks.length)),
            Caption(`next: ${tasks[0]!.title}`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Label(`${tasks.length} due`),
            RowList(() => tasks.map((t) => ({ id: t.id, title: t.title, trailing: t.due })), { max: 3 }),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
```

`cmux-app.json` (from `cmux ext new NAME --kind widget`; these lines matter):

```json
"implements": {
  "cmux.widget/1": {
    "export": "renderWidget",
    "title": "Today",
    "symbol": "checklist",
    "options": { "sizes": ["small", "medium"], "defaultSize": "small", "refresh": { "everySeconds": 60 } }
  }
},
"files": ["dist/", "preview/"]
```

## The checks and their fixes

| `check` | What it means | Fix |
|---|---|---|
| `type-size` | A font size that is not a type role | Use the role helper the fix names (`Caption` for 12, `Headline` for 15, ...) |
| `type-style` | A font name (`title`, `largeTitle`, ...) that the web and macOS draw at different sizes | `BigNumber`, `Heading` or `Headline` |
| `type-roles` | More than four text styles in one widget | One value, one title, `Body` and `Caption`; drop the rest |
| `line-limit` | A widget `Text` with no line limit | Use a role helper (which sets one), or `.lineLimit(1)` |
| `spacing` | A gap or padding off the scale | The step the fix names, written as a `SPACE` key |
| `color` | A hex color, or a name cmux does not know | A color role |
| `accents` | More than two accent colors in one view (`WidgetTitle`'s default `accent` counts) | `accent` for the one thing, `secondary` for the rest; with two state colors, `WidgetTitle(..., { tint: "secondary" })` |
| `contrast` | Text too faint on light or dark | `primary` or `secondary` |
| `system` | `cmux-design.json` does not read | The field and fix it names; until then, cmux's system is the one checked |
| `scene` | A recorded scene has no root | Record it again with `cmux ext shot --record` |

## A design system of your own

To change the roles, the scale or the color names for every view in one extension, put a
`cmux-design.json` beside `cmux-app.json`. It is merged over cmux's system, and anything it
leaves out stays cmux's:

```json
{
  "design": "cmux.design/1",
  "name": "My widgets",
  "type": { "numeral": { "size": 40, "weight": "bold" }, "code": { "size": 12, "weight": "regular", "monospaced": true } },
  "space": [0, 4, 8, 12, 16, 24, 32],
  "colors": { "brand": "accent", "muted": "secondary" },
  "limits": { "typeRoles": 5, "accents": 2 }
}
```

In code, `defineDesign(spec)` turns the file into a system. It throws, naming the field and
the fix, on an entry that does not hold, and `cmux ext dev` checks the file against the same
rules. Draw with the system you get back:

```ts
import { defineDesign, DesignSystemView, pane } from "cmux-extension-sdk"
import spec from "../cmux-design.json" with { type: "json" }
export const design = defineDesign(spec)
// design.text("numeral", "42"), design.text("code", "main.ts", { lines: 2 }), design.color("brand")
export const renderDesign = pane(() => DesignSystemView(design))
```

The rules for the file:
- Sizes run from 9 to 64 points, and a weight is `regular`, `medium`, `semibold` or `bold`.
- `space` is ascending and starts at 0.
- Each color name stands for one cmux color role.

`DesignSystemView(system)` draws a page showing the system: its type, spacing, colors,
components and limits. With no argument it shows cmux's own system, `cmuxDesign`. The example
is `examples/extensions/design-system`.
