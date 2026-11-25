# Edit cmux without the performance footguns

Most of cmux NEXT's past performance and flicker fixes undid one of a few mistakes. The rules and
warnings here catch those mistakes while you edit, in your own checkout or in a mod built from it, so
you don't have to rediscover them. They run in the same places for the cmux team and for anyone
else: `cmux live start` ([hot-reload.md](hot-reload.md)), `bun run dev`, `bun run check`, and the
pre-push hook.

## What you'll see

Save a file under `webviews/src/` while `cmux live` or `bun run dev` runs, and the dev server lints
it with the rules below. A finding prints in the dev server's log and in the page's console, one line
each:

```
[cmux perf lint] src/my-mod/List.tsx:42 cmux-perf/layout-thrash-in-loop: This loop reads layout ...
```

Nothing on save blocks a reload. The page also runs [runtime budgets](#runtime-budgets) for what only shows up live. `bun run check` and the pre-push hook run the same rules; the ones
marked **fails** below stop a push.

## The rules

| Rule | Catches | Do instead | Where it runs |
|---|---|---|---|
| `cmux-perf/layout-thrash-in-loop` | A loop (or `forEach`, `map`, ...) whose body both reads layout (`offsetHeight`, `getBoundingClientRect()`, `getComputedStyle()`, ...) and writes the DOM or styles. Each item forces its own layout, so the cost grows with the list. | Read every item first, then write. Fixed before in #33624 (transcript rows) and #34711 (hover sweep). | On save; `vp lint` and pre-push: **fails** |
| `cmux-perf/layout-read-after-write` | One layout read after a DOM or style write in the same function. | Read before you write, or read in the next frame. A deliberate probe (measuring a hidden copy) is fine; this rule only warns on save. | On save: warns |
| `cmux-lifecycle/effect-interval-cleanup` | A `setInterval` started in a React effect with no cleanup that clears it. | Return a cleanup, or tick on the shared page clock (`webviews/src/ui/pageClock.ts`), which also stops while the page is hidden (#28753). | `vp lint`, pre-push and CI: **fails** |

The rules live in `webviews/scripts/lint/perf-footguns.mjs` and `effect-cleanup.mjs`. Each is an
ESLint-style rule that the bundled Oxlint runs (`jsPlugins`). Silence a finding you've checked with a
reason on the line above it:

```ts
// oxlint-disable-next-line cmux-perf/layout-thrash-in-loop -- the writes go to a detached copy
```

## Runtime budgets

While a page runs from the dev server, it also watches for what only shows up live and warns once per place in the
page's console, as `[cmux perf budget] <class>: <value> over the budget of <budget> ... Fix: ...`:

| Budget | Fires when |
|---|---|
| `layout-shift` | Something moved 8 px or more after it painted with no input (Chromium) |
| `dom-breadth` | One element has more than 300 element children |
| `live-intervals` | More than 20 `setInterval` handles are live |
| `long-frame` | A frame takes over 50 ms (Chromium) |
| `react-commit` | A React root commits more than 120 times a second, or one update renders over 16 ms |

How to silence one, turn them off and read them in tests: [hot-reload.md](hot-reload.md#runtime-perf-budgets).

## Primitives that avoid them

| You want | Use |
|---|---|
| A long list or picker | `webviews/src/ui/VirtualList.tsx`, or the `virtualRows` prop on `ui/Combobox.tsx`: the visible window only (#36132) |
| Something that ticks (a clock, a spinner, elapsed time) | `ui/pageClock.ts` (`useTicking`): one shared tick, none while hidden |
| A streamed value that changes many times a second | One small store read with `useSyncExternalStore` in the row that shows it, not state at the page root (#34004) |
| A popover or card at its final place on its first frame | Place it before it shows, from a measure in a layout effect, not after a paint |
