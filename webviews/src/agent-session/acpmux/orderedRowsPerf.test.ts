import { expect, test } from "bun:test";
import { perfSeries, recordPerfResults } from "../../../scripts/perf-result.mjs";
import { OrderedRows } from "./direct";
import { turnViewFrom } from "./conversation/turns";

const EVENT_COUNT = 192_000;
/** Repeated calls per measurement: each call is one sample, their sum the budgeted total. */
const REPEATS = 20;

/** Calls `call` REPEATS times: the results, each call's time and the sum of the times. */
function timedCalls<T>(call: () => T): { values: T[]; ms: number[]; totalMs: number } {
  const values: T[] = [];
  const ms: number[] = [];
  for (let index = 0; index < REPEATS; index += 1) {
    const started = performance.now();
    values.push(call());
    ms.push(performance.now() - started);
  }
  return { values, ms, totalMs: ms.reduce((sum, value) => sum + value, 0) };
}

const row = (index: number) => ({
  id: `row-${index}`,
  version: 1,
  at: index,
  kind: "assistant" as const,
  text: "fixture",
});

test("a long transcript reuses its ordered snapshot between metadata emissions", () => {
  const rows = new OrderedRows();
  for (let index = 0; index < EVENT_COUNT; index += 1) {
    rows.current = index + 1;
    rows.set(`row-${index}`, row(index));
    rows.current = undefined;
  }

  const first = rows.sorted();
  const viewRows = first.map((item, index) => (index % 2 === 0 ? { ...item, kind: "user" as const } : item));
  const expanded = new Set<string>();
  const previous = turnViewFrom(viewRows, expanded);
  const turnViews = timedCalls(() => turnViewFrom(viewRows, expanded, {}, previous));
  const views = turnViews.values;
  const viewElapsed = turnViews.totalMs;
  const sortedSnapshots = timedCalls(() => rows.sorted());
  const snapshots = sortedSnapshots.values;
  const elapsed = sortedSnapshots.totalMs;
  console.log(
    `transcript-perf rows=${EVENT_COUNT} repeatedSnapshots=${REPEATS} elapsedMs=${elapsed.toFixed(2)} repeatedTurns=${REPEATS} turnViewElapsedMs=${viewElapsed.toFixed(2)}`,
  );
  // Before the budgets below: a lab run (PERF_RESULT_DIR) keeps the samples of a slow run too.
  recordPerfResults({
    story: "webviews",
    engine: "none",
    series: [
      perfSeries("web.ordered_rows.snapshot", "ms", sortedSnapshots.ms),
      perfSeries("web.ordered_rows.turn_view", "ms", turnViews.ms),
    ],
  });

  expect(views.every((view) => view === previous)).toBe(true);
  expect(snapshots.every((snapshot) => snapshot === first)).toBe(true);
  expect(first).toHaveLength(EVENT_COUNT);
  // This is an allocation guard as well as an identity check: metadata heartbeats must not copy
  // every transcript row while no transcript row changed.
  expect(elapsed).toBeLessThan(50);
  expect(viewElapsed).toBeLessThan(100);

  rows.current = EVENT_COUNT + 1;
  rows.set(`row-${EVENT_COUNT}`, row(EVENT_COUNT));
  rows.current = undefined;
  const changed = rows.sorted();
  expect(changed).not.toBe(first);
  expect(changed).toHaveLength(EVENT_COUNT + 1);
});
