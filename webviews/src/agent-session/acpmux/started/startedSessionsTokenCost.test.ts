// l10n-allow-file: test fixture text, not shipped UI.
// A streamed token in a long chat whose agent started other chats costs the rows it changed, not
// the chat (Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference").
// `withStartedSessions` (startedSessions.ts) read every row and made a new array of them on each
// update, and said nothing of its kept prefix, so every pass after it (runningTray.ts
// `withSubagentLines`, turns.ts `turnViewFrom`, the layout) walked the whole chat again to find
// where it changed. The same class as subagents/subagentLinesTokenCost.test.ts.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { keptPrefix, noteKeptPrefix, prefixWalks } from "../conversation/prefixFlatMap";
import { STARTED_SESSIONS, type StartedCache, type StartedSession, withStartedSessions } from "./startedSessions";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const started = (id: string, createdAt?: number, extra: Partial<StartedSession> = {}): StartedSession => ({
  sessionId: id,
  title: `Task ${id}`,
  state: "idle",
  ...(createdAt !== undefined ? { createdAt } : {}),
  ...extra,
});

const TURN = 50;
/// A chat of `count` rows: a prompt every TURN rows, each turn ending in its summary but the last,
/// which ends in a streaming reply. Row `index` is at time `index`.
function chat(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let index = 0; index < count; index += 1) {
    const kind =
      index % TURN === 0 ? "user" : index % TURN === TURN - 1 && index < count - 1 ? "turnSummary" : "assistant";
    rows.push(row(`r${index}`, kind, index, { text: `row ${index}` }));
  }
  return rows;
}

/// The next snapshot, as the client makes it: the last row a new object, the rest kept and said so.
function token(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const last = rows.at(-1)!;
  const next = [...rows.slice(0, -1), { ...last, version: last.version + 1, text: `${last.text} more` }];
  noteKeptPrefix(next, rows, rows.length - 1);
  return next;
}

/// `rows` with the rows past their end appended, said to keep all of `rows`.
function grown(rows: readonly AcpmuxRow[], ...more: AcpmuxRow[]): AcpmuxRow[] {
  const next = [...rows, ...more];
  noteKeptPrefix(next, rows, rows.length);
  return next;
}

/// `rows`, counting each read of a row by index.
function counted(rows: AcpmuxRow[]): { rows: AcpmuxRow[]; reads: { count: number } } {
  const reads = { count: 0 };
  const proxy = new Proxy(rows, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads.count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  return { rows: proxy, reads };
}

/// A card by what it draws (a fresh pass numbers its versions from 1), every other row as it is.
const shape = (rows: readonly AcpmuxRow[]) =>
  rows.map((entry) =>
    entry.kind === STARTED_SESSIONS ? `${entry.id}@${entry.at}:${JSON.stringify(entry.started)}` : entry,
  );

test("a streamed token in a 20,000-row chat with started chats reads and walks fewer than 100 rows", () => {
  const cache: StartedCache = new Map();
  // Chats started in the 4th turn and the 200th.
  const children = [started("early", 3 * TURN + 5), started("middle", 199 * TURN + 5)];
  const firstRows = chat(20_000);
  const first = counted(firstRows);
  const before = withStartedSessions(first.rows, children, cache);
  const next = counted(token(firstRows));
  noteKeptPrefix(next.rows, first.rows, firstRows.length - 1);
  const walked = prefixWalks.rows;
  const after = withStartedSessions(next.rows, children, cache);
  // The pass reads the rows the token changed, not the chat.
  expect(next.reads.count).toBeLessThan(100);
  // The next pass (runningTray.ts `withSubagentLines`, turns.ts `turnViewFrom`) asks where the rows changed.
  const kept = keptPrefix(before, after);
  expect(prefixWalks.rows - walked).toBeLessThan(100);
  // Every row but the streaming one is kept (the two cards add one each).
  expect(after.length).toBe(20_002);
  expect(kept).toBe(after.length - 1);
  expect(shape(after)).toEqual(shape(withStartedSessions(token(firstRows), children)));
});

test("rows kept across updates draw what a fresh pass draws, as turns, summaries and chats come and go", () => {
  const cache: StartedCache = new Map();
  let rows = chat(TURN * 4 + 10);
  let children = [started("a", TURN + 3), started("b", 3 * TURN + 2)];
  const check = () => {
    const out = withStartedSessions(rows, children, cache);
    expect(shape(out)).toEqual(shape(withStartedSessions(rows, children)));
    return out;
  };
  let out = check();
  // A token in the last turn, then a chat started in it: its card goes after the streaming row.
  rows = token(rows);
  out = check();
  children = [...children, started("c", rows.length + 1)];
  out = check();
  expect(out.at(-1)!.kind).toBe(STARTED_SESSIONS);
  rows = token(rows);
  const streaming = check();
  // Only the streaming row and the card after it changed.
  expect(keptPrefix(out, streaming)).toBe(streaming.length - 2);
  // The turn's summary lands: its card moves before it.
  rows = grown(rows, row("summary", "turnSummary", rows.length));
  out = check();
  expect(out.at(-2)!.kind).toBe(STARTED_SESSIONS);
  // A new prompt and reply; a chat with no `createdAt` joins the last turn's card.
  rows = grown(rows, row("prompt", "user", rows.length), row("reply", "assistant", rows.length + 1));
  children = [...children, started("old")];
  out = check();
  // A chat in the middle changes state: its card draws again, the rows before it are kept.
  const middle = out.findIndex((entry) => entry.id === `${STARTED_SESSIONS}-b`);
  children = children.map((child) => (child.sessionId === "b" ? { ...child, state: "running" } : child));
  const changed = check();
  expect(keptPrefix(out, changed)).toBe(middle);
  // A chat archived: its card goes.
  children = children.filter((child) => child.sessionId !== "a");
  out = check();
  expect(out.some((entry) => entry.id === `${STARTED_SESSIONS}-a`)).toBe(false);
  // A snapshot that shares no rows (another load of the chat).
  rows = chat(TURN * 2 + 3).map((entry) => ({ ...entry }));
  out = check();
  // The same rows and chats give the same array back.
  expect(withStartedSessions(rows, children, cache)).toBe(out);
  // No chats: the rows as they are.
  expect(withStartedSessions(rows, [], cache)).toBe(rows);
});
