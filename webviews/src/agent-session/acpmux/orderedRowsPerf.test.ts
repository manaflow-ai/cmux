import { expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import { keptPrefix, noteKeptPrefix } from "./conversation/prefixFlatMap";
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

test("each snapshot says how many leading rows it kept, so a pass over a long chat starts at the change", () => {
  const rows = new OrderedRows();
  const COUNT = 5_000;
  for (let index = 0; index < COUNT; index += 1) {
    rows.current = index + 1;
    rows.set(`row-${index}`, row(index));
    rows.current = undefined;
  }
  const first = rows.sorted();
  // A tool call starts: a new row at the end. The rows before it are the same objects.
  rows.current = COUNT + 1;
  rows.set("call", { ...row(COUNT), id: "call" });
  rows.current = undefined;
  const started = rows.sorted();
  expect(keptPrefix(first, started)).toBe(COUNT);
  // The call ends: its slot is written in place, and only the rows before it are kept.
  rows.current = COUNT + 2;
  rows.set("call", { ...row(COUNT), id: "call", version: 2 });
  rows.current = undefined;
  const ended = rows.sorted();
  expect(keptPrefix(started, ended)).toBe(COUNT);
  // Two writes, the earlier one first in the order: the prefix ends at the earlier.
  rows.current = COUNT + 3;
  rows.set("row-10", { ...row(10), version: 2 });
  rows.set("row-4000", { ...row(4000), version: 2 });
  rows.current = undefined;
  const two = rows.sorted();
  expect(keptPrefix(ended, two)).toBe(10);
  // A row taken out reorders the rest: no claim, so the walk answers, and answers right.
  rows.delete("row-20");
  const removed = rows.sorted();
  expect(keptPrefix(two, removed)).toBe(20);
  expect(removed[20]!.id).toBe("row-21");
});

test("a noted kept prefix answers for its own pair only, without a walk", () => {
  const a = [{}, {}, {}, {}, {}];
  const b = [...a, {}];
  // A maker may claim less than the true prefix (5 here): keptPrefix takes its word, no walk.
  noteKeptPrefix(b, a, 2);
  expect(keptPrefix(a, b)).toBe(2);
  // Another array with the same rows was not named: it is walked.
  expect(keptPrefix(a.slice(), b)).toBe(5);
  // A claim past either array's end is cut to it.
  const c = a.slice(0, 3);
  noteKeptPrefix(c, a, 99);
  expect(keptPrefix(a, c)).toBe(3);
});
