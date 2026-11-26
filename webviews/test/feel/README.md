# Feel checks: a simulated cursor on any surface

Leo, 2026-11-22: "these should be doable via automation. the "feel" and "vibes" thing. you can simulate
cursors clicking around", and on the simulated-cursor check: "i mean this to say we can use it on various
other parts of the app".

A feel check points a simulated hand at one gallery entry and judges what it sees with measured numbers,
not screenshots. Any surface with a gallery entry can have one: the composer hat, the plan tray, sidebar
drag and pin, thought rows, context menus, the composer. Each check writes `report.md`, `report.json` and
one `.webm` per scenario (with a cursor dot) to `$CMUX_FEEL_OUT/<component>`, default
`$TMPDIR/cmux-feel/<component>`.

```
cd webviews && CMUX_BROWSER_TESTS=1 bun test test/feel-<surface>.test.ts
```

CI runs these files in the browser lane (GitHub Actions installs chromium). `CMUX_FEEL_RECORD=0` turns off
the recordings.

## The parts

| File          | What it gives a check                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `stage.ts`    | `feelStage({entry, variant, component, viewport, prepare, known})`: the gallery dev server, a fresh recorded page per scenario, the report at the end. `scenario(name, run)`, `testFor(name)`, `expectPass`.                                                                                                                                                                                                 |
| `cursor.ts`   | The hands: `drag` along `dragPath(from, to, "slow" \| "fast" \| "jitter" \| "burst" \| "overshoot")`, `click` (with `wobble`), `doubleClick`, `play`, `aroundHandle` (the misses around a handle). Seeded: the same path every run. Playwright's real mouse, so the events are trusted, with capture and hit testing.                                                                                        |
| `probe.ts`    | `record(page, spec, act)`: reads every painted frame while `act` runs. A `ProbeSpec` names the `boxes` (selectors whose rects to read), `texts` (live rows: visible words and width) and `states` (attributes).                                                                                                                                                                                              |
| `verdicts.ts` | Pure maths on the trace: `follow` (an edge 1:1 on the hand: error, jumps, release move, coverage), `still` (what a non-drag click moved or changed, layout shift), `flips` (hysteresis), `snapDistance`, `churn` (swaps per second, shortest hold, width changes), `continuity` (one move, one way, no pop). `Verdicts` collects `atMost`, `atLeast` and `equals`. Unit tests: `test/feel-verdicts.test.ts`. |

## A new surface in one file

```ts
await requireBrowserLane("feel-sidebar.test.ts", async () => {
  if (!(await chromiumLaunches())) return describe.skip("feel: sidebar", () => test("chromium", () => {}));
  const { scenario, testFor } = feelStage({
    entry: "sidebar.workspaces",
    variant: "many",
    component: "sidebar",
    viewport: { width: 320, height: 720 },
  });
  const SPEC = {
    boxes: { row: ".sidebar-row[data-dragging]" },
    states: { pinned: { selector: ".sidebar-row", attr: "data-pinned" } },
  };
  testFor("drag-jitter")("a row dragged by a shaky hand stays under it", async () => {
    expectPass(
      await scenario("drag-jitter", async (page, v) => {
        const trace = await record(page, SPEC, () => drag(page, from, dragPath(from, to, "jitter")));
        const report = follow(trace, { box: "row", edge: "top", slop: 4 });
        v.atMost("row offset from the grab point", report.maxError, 3, " px");
        v.atLeast("row travel / hand travel", report.coverage, 0.9);
        return report;
      }),
    );
  });
});
```

What every surface should be put through: drags slow, fast, shaky and in bursts; a click that is not a
drag; misses just around each handle; a double-click and repeats; bursts and extremes in its data (1, 5
and 50 items; short and huge text). A stage of its own (a `*.gallery.ts` entry) gives the hand room, like
`agent-pane.feel-tray`.

## Known reds

A scenario that fails on the base today goes in `known` with who is fixing it. It runs as `test.failing`,
so the base stays green while the report still says FAIL. The fix that makes it pass fails the run until it
removes that scenario's line, so the fix PR is where the check turns green.
