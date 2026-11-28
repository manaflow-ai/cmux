// A tool call's start and end cost the pane's per-snapshot passes the rows they changed, at any
// chat length: the client says how many leading rows each snapshot kept (direct.ts
// `OrderedRows.sorted`, prefixFlatMap.ts `noteKeptPrefix`), so no pass walks the chat to find the
// change (Leo, 2026-11-11: "the tool calls coming in are still kinda sluggish"; bench/transcript-
// replay.bench.ts god log: markRows, sessionEdits, startedNames, mergeInboxNotices and
// withoutQuietThoughts each read every row of a 35,000-row chat per tool call). Counts, not ms.
import { expect, test } from "bun:test";
import { mergeInboxNotices } from "../src/agent-session/acpmux/conversation/inboxNotice";
import { PrefixFlatCache, prefixWalks } from "../src/agent-session/acpmux/conversation/prefixFlatMap";
import { startedNames, type StartedNames } from "../src/agent-session/acpmux/conversation/startedNames";
import { withoutQuietThoughts } from "../src/agent-session/acpmux/conversation/thoughts";
import { OrderedRows } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { markRows, type RowMarks } from "../src/agent-session/acpmux/rowMarks";
import { sessionEdits, type SessionEdits } from "../src/agent-session/acpmux/turnChanges/sessionRows";

const reply = (index: number): AcpmuxRow => ({ id: `r${index}`, version: 1, at: index, kind: "assistant", text: "ok" });
const call = (id: string, at: number, status: "in_progress" | "completed"): AcpmuxRow => ({
  id,
  version: status === "completed" ? 2 : 1,
  at,
  kind: "activity",
  items: [{ kind: "tool", text: "Read", tool: { id, title: "Read", kind: "read", status } }],
});

/// The rows walked over `calls` tool calls (each a start and an end) after a chat of `size` rows.
function walkedPerCall(size: number, calls: number): number {
  const rows = new OrderedRows();
  let seq = 0;
  const event = (id: string, row: AcpmuxRow) => {
    rows.current = seq += 1;
    rows.set(id, row);
    rows.current = undefined;
  };
  for (let index = 0; index < size; index += 1) event(`r${index}`, reply(index));
  let marks: RowMarks | undefined;
  let edits: SessionEdits | undefined;
  let names: StartedNames | undefined;
  const passes = () => {
    const snapshot = rows.sorted();
    marks = markRows(snapshot, marks);
    edits = sessionEdits(snapshot, edits);
    names = startedNames(snapshot, names);
    mergeInboxNotices(withoutQuietThoughts(snapshot, true));
  };
  passes();
  const before = prefixWalks.rows;
  for (let index = 0; index < calls; index += 1) {
    const id = `call-${index}`;
    event(id, call(id, size + index, "in_progress"));
    passes();
    event(id, call(id, size + index, "completed"));
    passes();
  }
  return (prefixWalks.rows - before) / calls;
}

test("a tool call's start and end walk no more rows in a long chat than in a short one", () => {
  const short = walkedPerCall(2_000, 20);
  const long = walkedPerCall(20_000, 20);
  // Before the client said what it kept, each call walked every row once per pass (about 40,000
  // rows a call at 20,000 rows).
  expect(long).toBeLessThanOrEqual(short + 4);
  expect(long).toBeLessThan(100);
});

test("a view's next snapshot walks its own last pass, not every view's pass the cache holds", () => {
  const cache = new PrefixFlatCache<AcpmuxRow, AcpmuxRow>((row) => [row]);
  const rows = Array.from({ length: 10_000 }, (_, index) => reply(index));
  // Another view of the same chat, shorter (a child chat's or a scope's rows), read after it: the
  // newest pass the cache holds.
  cache.read(rows);
  const other = [...rows.slice(0, 9_000), reply(-1)];
  cache.read(other);
  // This view's next snapshot, which no maker named: one walk finds all but its last row kept, and
  // no other pass could save more than reading that row costs.
  const next = [...rows, reply(10_000)];
  const before = prefixWalks.rows;
  expect(cache.read(next).items).toEqual(next);
  expect(prefixWalks.rows - before).toBeLessThanOrEqual(rows.length);
});

/// The rows walked per streamed record (a tool call's start, then its end) when the turn view and the
/// transcript's layout read each snapshot of a chat of `turns` settled turns, as App.tsx and
/// VirtualTranscript do: `turnViewFrom` over the client's snapshot, then `layoutConversation` over
/// the drawn rows, given the last layout.
async function walkedPerRecord(turns: number, records: number): Promise<number> {
  const { turnViewFrom } = await import("../src/agent-session/acpmux/conversation/turns");
  const { layoutConversation } = await import("../src/agent-session/acpmux/model");
  const rows = new OrderedRows();
  let seq = 0;
  const event = (row: AcpmuxRow) => {
    rows.current = seq += 1;
    rows.set(row.id, row);
    rows.current = undefined;
  };
  for (let turn = 0; turn <= turns; turn += 1) {
    event({ id: `u${turn}`, version: 1, at: seq, kind: "user", text: `turn ${turn}` });
    if (turn < turns) event({ ...reply(seq), id: `r${turn}` });
  }
  const folds = new Set<string>();
  const options = { working: true, now: 1_000_000 };
  const cache = new Map();
  const known = new WeakMap();
  let view = turnViewFrom(rows.sorted(), folds, options);
  let layout = layoutConversation(view.rows, 720, cache, undefined, known);
  const passes = () => {
    const next = turnViewFrom(rows.sorted(), folds, options, view);
    layout = layoutConversation(next.rows, 720, cache, undefined, known, { rows: view.rows, layout });
    view = next;
  };
  const before = prefixWalks.rows;
  for (let index = 0; index < records; index += 1) {
    const id = `live-${index}`;
    event(call(id, seq, "in_progress"));
    passes();
    event(call(id, seq, "completed"));
    passes();
  }
  return (prefixWalks.rows - before) / (2 * records);
}

test("a streamed record's turn view and layout walk no more rows in a long chat than in a short one", async () => {
  const short = await walkedPerRecord(200, 20);
  const long = await walkedPerRecord(5_000, 20);
  // The layout walked every drawn row once per record to find where the record changed them, and the
  // turn view handed over a new array no pass was told about: 10,000 rows a record at 5,000 turns.
  expect(long).toBeLessThanOrEqual(short + 4);
  expect(long).toBeLessThan(100);
});

test("the rail's offered choices read only the turns an update changed, and stay what a whole read says", async () => {
  const { railShowsOffered } = await import("../src/agent-session/acpmux/threadMinimap/model");
  type Turns = Parameters<typeof railShowsOffered>[0];
  type Ticks = Parameters<typeof railShowsOffered>[1];
  const turn = (index: number, fields: object = {}) => ({ id: `t${index}`, ...fields }) as unknown as Turns[number];
  const tick = (from?: string) => ({ from, ...(from ? { others: true } : {}) }) as unknown as Ticks[number];
  const turns: Turns[number][] = Array.from({ length: 1_000 }, (_, index) => turn(index));
  const ticks: Ticks[number][] = turns.map(() => tick());
  expect([...railShowsOffered(turns, ticks)].map(String).sort()).toEqual(["mine", "prompts"]);
  // A reply and a received prompt at the end: the next update reads those turns, not the first 1,000.
  const more = [...turns, turn(1_000, { replyAt: 5 }), turn(1_001, { metadata: { toolCount: 2 } })];
  const moreTicks = [...ticks, tick(), tick("lane-1")];
  expect([...railShowsOffered(more, moreTicks)].map(String).sort()).toEqual(
    ["everything", "mine", "prompts", "received", "replies", "tools"].sort(),
  );
  // The same arrays again: the same set, not a new one.
  const again = railShowsOffered(more, moreTicks);
  expect(railShowsOffered(more, moreTicks)).toBe(again);
  // Back to the shorter chat (another chat's rail): what it holds alone.
  expect([...railShowsOffered(turns, ticks)].map(String).sort()).toEqual(["mine", "prompts"]);
});
