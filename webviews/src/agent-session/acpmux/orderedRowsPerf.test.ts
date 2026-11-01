import { expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import { turnViewFrom } from "./conversation/turns";

const EVENT_COUNT = 192_000;

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
  const viewStarted = performance.now();
  const views = Array.from({ length: 20 }, () => turnViewFrom(viewRows, expanded, {}, previous));
  const viewElapsed = performance.now() - viewStarted;
  const started = performance.now();
  const snapshots = Array.from({ length: 20 }, () => rows.sorted());
  const elapsed = performance.now() - started;
  console.log(
    `transcript-perf rows=${EVENT_COUNT} repeatedSnapshots=20 elapsedMs=${elapsed.toFixed(2)} repeatedTurns=20 turnViewElapsedMs=${viewElapsed.toFixed(2)}`,
  );

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
