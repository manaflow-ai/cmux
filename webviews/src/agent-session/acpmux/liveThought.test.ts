import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { drewThoughts, liveThought, thoughtOnly } from "./liveThought";
import { markOneRowChange } from "./rowChanges";

const snapshot = (rows: AcpmuxRow[]): AcpmuxSnapshot => ({ rows }) as AcpmuxSnapshot;

const row = (id: string, thought: AcpmuxActivity, version: number): AcpmuxRow => ({
  id,
  version,
  at: 1,
  kind: "activity",
  items: [thought],
  streaming: true,
});

test("thought fast path accepts an equivalent shaped transcript item", () => {
  const beforeThought: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const afterThought: AcpmuxActivity = { ...beforeThought, text: "Read the helper", endedAt: 3 };
  const previousRow = row("activity-shaped", beforeThought, 1);
  const nextRow = row("activity-shaped", afterThought, 2);
  const previous = snapshot([previousRow]);
  const next = snapshot([nextRow]);
  markOneRowChange(next.rows, previous.rows, 0);

  // `withoutQuietThoughts`/`turns.ts` may hand the transcript a value-equivalent clone.
  drewThoughts([row("activity-shaped", { ...beforeThought }, 9)]);

  expect(thoughtOnly(previous, next)).toEqual({ id: nextRow.id, before: beforeThought, after: afterThought });
});

test("thought fast path accepts a value-equivalent settled projection", () => {
  const beforeThought: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const afterThought: AcpmuxActivity = { ...beforeThought, text: "Read the helper", endedAt: 3 };
  const previous = {
    ...snapshot([row("settled-projection", beforeThought, 1)]),
    settled: { lastSeq: 9, forkSeqs: [4, 7] },
  };
  const next = {
    ...snapshot([row("settled-projection", afterThought, 2)]),
    settled: { lastSeq: 9, forkSeqs: [4, 7] },
  };
  markOneRowChange(next.rows, previous.rows, 0);
  drewThoughts([row("settled-projection", { ...beforeThought }, 9)]);

  expect(thoughtOnly(previous, next)).toEqual({ id: next.rows[0]!.id, before: beforeThought, after: afterThought });
});

test("thought fast path keeps the baseline after a shaped first update", () => {
  const first: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const second: AcpmuxActivity = { ...first, text: "Read the helper", endedAt: 3 };
  const third: AcpmuxActivity = { ...second, text: "Read the helper before editing", endedAt: 4 };
  const previous = snapshot([row("activity-shaped-next", first, 1)]);
  const next = snapshot([row("activity-shaped-next", second, 2)]);
  markOneRowChange(next.rows, previous.rows, 0);
  drewThoughts([row("activity-shaped-next", { ...first }, 9)]);

  const change = thoughtOnly(previous, next);
  expect(change).toBeDefined();
  liveThought.set(change!.id, change!.before, change!.after);

  const later = snapshot([row("activity-shaped-next", third, 3)]);
  markOneRowChange(later.rows, next.rows, 0);
  expect(thoughtOnly(next, later)).toEqual({ id: next.rows[0]!.id, before: second, after: third });
});

test("thought fast path rejects a shaped item with different text", () => {
  const beforeThought: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const afterThought: AcpmuxActivity = { ...beforeThought, text: "Read the helper", endedAt: 3 };
  const previous = snapshot([row("activity-shaped-different", beforeThought, 1)]);
  const next = snapshot([row("activity-shaped-different", afterThought, 2)]);
  markOneRowChange(next.rows, previous.rows, 0);
  drewThoughts([row("activity-shaped-different", { ...beforeThought, text: "Merged earlier thought\n\nRead" }, 9)]);

  expect(thoughtOnly(previous, next)).toBeUndefined();
});

const prompt: AcpmuxRow = { id: "prompt", version: 1, at: 1, kind: "user", text: "go" } as AcpmuxRow;
const closedWork = (open: boolean): AcpmuxRow =>
  ({ id: "worked-prompt", version: 1, at: 1, kind: "worked", turnPhase: "running", foldOpen: open }) as AcpmuxRow;
const line: AcpmuxRow = { id: "thinking-live", version: 1, at: 1, kind: "thinking" } as AcpmuxRow;

test("thought fast path takes a thought the running turn's closed fold hides", () => {
  const first: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const second: AcpmuxActivity = { ...first, text: "Read the helper", endedAt: 3 };
  const third: AcpmuxActivity = { ...second, text: "Read the helper first", endedAt: 4 };
  const previous = snapshot([prompt, row("hidden-thought", first, 1)]);
  const next = snapshot([prompt, row("hidden-thought", second, 2)]);
  markOneRowChange(next.rows, previous.rows, 1);
  // The transcript drew the prompt, its closed "Working for" and the live line: no row of the work.
  drewThoughts([prompt, closedWork(false), line]);

  // Without the pane's drawn rows it cannot tell what the hidden row holds.
  expect(thoughtOnly(previous, next)).toBeUndefined();
  const change = thoughtOnly(previous, next, previous.rows);
  expect(change).toEqual({ id: "hidden-thought", before: first, after: second });
  liveThought.set(change!.id, change!.before, change!.after);

  // The next chunk moves on from the store's thought while the pane still holds the first.
  const later = snapshot([prompt, row("hidden-thought", third, 3)]);
  markOneRowChange(later.rows, next.rows, 1);
  expect(thoughtOnly(next, later, previous.rows)).toEqual({ id: "hidden-thought", before: second, after: third });
});

test("thought fast path redraws a hidden thought once the fold is open or the row draws", () => {
  const first: AcpmuxActivity = { kind: "thought", text: "Plan", startedAt: 1, endedAt: 2 };
  const second: AcpmuxActivity = { ...first, text: "Plan the change", endedAt: 3 };
  const previous = snapshot([prompt, row("fold-thought", first, 1)]);
  const next = snapshot([prompt, row("fold-thought", second, 2)]);
  markOneRowChange(next.rows, previous.rows, 1);

  // An open fold draws the run: the hidden path never takes it.
  drewThoughts([prompt, closedWork(true), line]);
  expect(thoughtOnly(previous, next, previous.rows)).toBeUndefined();
  // A transcript that drew the row with another thought than the client's: the row must draw.
  drewThoughts([prompt, closedWork(false), row("fold-thought", { ...first, text: "Other" }, 5), line]);
  expect(thoughtOnly(previous, next, previous.rows)).toBeUndefined();
  // A turn summary between the prompt and the row: an ended stretch's runs draw.
  const summary = { id: "summary", version: 1, at: 1, kind: "turnSummary" } as AcpmuxRow;
  const endedBefore = snapshot([prompt, summary, row("fold-thought", first, 1)]);
  const endedNext = snapshot([prompt, summary, row("fold-thought", second, 2)]);
  markOneRowChange(endedNext.rows, endedBefore.rows, 2);
  drewThoughts([prompt, closedWork(false), summary, line]);
  expect(thoughtOnly(endedBefore, endedNext, endedBefore.rows)).toBeUndefined();
});
