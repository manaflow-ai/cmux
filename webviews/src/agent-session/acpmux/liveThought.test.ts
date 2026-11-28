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

const prompt: AcpmuxRow = { id: "user-1", version: 1, at: 1, kind: "user" };
const header = (foldOpen: boolean): AcpmuxRow => ({
  id: "worked-user-1",
  version: 1,
  at: 1,
  kind: "worked",
  turnPhase: "running",
  foldOpen,
});
const line: AcpmuxRow = { id: "thinking-live", version: 1, at: 1, kind: "thinking" };

const hiddenChange = (tail: AcpmuxRow[] = []) => {
  const beforeThought: AcpmuxActivity = { kind: "thought", text: "Read", startedAt: 1, endedAt: 2 };
  const afterThought: AcpmuxActivity = { ...beforeThought, text: "Read the helper", endedAt: 3 };
  const previous = snapshot([prompt, row("activity-folded", beforeThought, 1), ...tail]);
  const next = snapshot([prompt, row("activity-folded", afterThought, 2), ...tail]);
  markOneRowChange(next.rows, previous.rows, 1);
  return { previous, next, beforeThought, afterThought };
};

test("thought fast path takes a thought the running turn's closed Working for hides", () => {
  const { previous, next, beforeThought, afterThought } = hiddenChange();
  drewThoughts([prompt, header(false), line]);

  expect(thoughtOnly(previous, next)).toEqual({ id: "activity-folded", before: beforeThought, after: afterThought });
});

test("thought fast path draws the pane for a hidden thought once the fold is open", () => {
  const { previous, next } = hiddenChange();
  drewThoughts([prompt, header(true), line]);

  expect(thoughtOnly(previous, next)).toBeUndefined();
});

test("thought fast path draws the pane for a hidden row of an earlier turn", () => {
  const steer: AcpmuxRow = { id: "user-2", version: 1, at: 2, kind: "user" };
  const { previous, next } = hiddenChange([steer]);
  drewThoughts([prompt, header(false), line]);

  expect(thoughtOnly(previous, next)).toBeUndefined();
});

test("thought fast path draws the pane for a row the closed fold still draws with an older thought", () => {
  const { previous, next } = hiddenChange();
  const stale: AcpmuxActivity = { kind: "thought", text: "Re", startedAt: 1, endedAt: 1 };
  drewThoughts([prompt, header(false), row("activity-folded", stale, 9), line]);

  expect(thoughtOnly(previous, next)).toBeUndefined();
});
