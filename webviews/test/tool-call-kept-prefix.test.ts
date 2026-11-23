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
