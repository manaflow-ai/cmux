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

const placed = (rows: OrderedRows, index: number, kind: "assistant" | "compaction" | "user" = "assistant") => {
  rows.current = index + 1;
  rows.set(`row-${index}`, { ...row(index), kind } as never);
  rows.current = undefined;
};

test("dropping the newest row keeps the order; dropping any other row sorts again, to the same order", () => {
  const rows = new OrderedRows();
  for (let index = 0; index < 6; index += 1) placed(rows, index);
  const full = () => [...rows.values()].map((item) => item.id).sort((a, b) => rows.orderOf(a) - rows.orderOf(b));
  expect(rows.sorted().map((item) => item.id)).toEqual(full());
  rows.delete("row-5");
  expect(rows.sorted().map((item) => item.id)).toEqual(full());
  placed(rows, 6);
  rows.delete("row-2");
  placed(rows, 7);
  expect(rows.sorted().map((item) => item.id)).toEqual(full());
  expect(rows.sorted().map((item) => item.id)).toEqual(["row-0", "row-1", "row-3", "row-4", "row-6", "row-7"]);
});

test("scanBack reads from the newest row and stops when asked; compactionRows tracks the compactions", () => {
  const rows = new OrderedRows();
  for (let index = 0; index < 5; index += 1)
    placed(rows, index, index === 1 || index === 3 ? "compaction" : "assistant");
  const seen: string[] = [];
  rows.scanBack((item) => {
    seen.push(item.id);
    return item.id !== "row-2";
  });
  expect(seen).toEqual(["row-4", "row-3", "row-2"]);
  expect(rows.compactionRows().map((item) => item.id)).toEqual(["row-1", "row-3"]);
  rows.delete("row-1");
  placed(rows, 3, "assistant");
  expect(rows.compactionRows()).toEqual([]);
  rows.clear();
  expect(rows.compactionRows()).toEqual([]);
});
