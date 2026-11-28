// l10n-allow-file: test fixtures.
// A quiet call under the running turn's closed "Working for" moves only the live line: the pane
// keeps its snapshot and the line hears the call (liveCallLine.ts). Anything the line cannot tell
// from that one call, or a pass that draws the pane's older rows, redraws the pane.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { LIVE_THINKING, WORKED, turnView } from "./conversation/turns";
import {
  callOnly,
  drewLiveLine,
  lineCalledNow,
  liveCallLine,
  liveCallLineHeard,
  setLiveLine,
  setOpenRows,
} from "./liveCallLine";
import { drewThoughts } from "./liveThought";
import { markOneRowChange } from "./rowChanges";

const snapshot = (rows: AcpmuxRow[]): AcpmuxSnapshot => ({ rows, connection: "tool_call" }) as AcpmuxSnapshot;

const read = (id: string, status: string, kind = "read"): AcpmuxActivity => ({
  kind: "tool",
  text: `Read src/${id}.ts`,
  tool: {
    id,
    title: `Read src/${id}.ts`,
    kind,
    status,
    locations: [{ path: `/mock/src/${id}.ts` }],
    startedAt: 3_000,
    ...(status === "completed" ? { endedAt: 3_100, output: "export {}" } : {}),
  },
});

const prompt: AcpmuxRow = { id: "p1", version: 1, at: 1_000, kind: "user", text: "Read the helpers" };
const reply: AcpmuxRow = { id: "m1", version: 1, at: 2_000, kind: "assistant", text: "Looking." } as AcpmuxRow;
const work = (version: number, items: AcpmuxActivity[]): AcpmuxRow =>
  ({ id: "a1", version, at: 2_500, kind: "activity", items }) as AcpmuxRow;

const options = { now: 10_000, working: true };

/// The pane draws `snapshot`: the transcript shapes and draws its rows (VirtualTranscript).
function paneDraws(snap: AcpmuxSnapshot, expanded = new Set<string>()): AcpmuxRow[] {
  liveCallLine.redraw(snap);
  return transcriptDraws(snap, expanded);
}

function transcriptDraws(snap: AcpmuxSnapshot, expanded = new Set<string>()): AcpmuxRow[] {
  const view = turnView(snap.rows as AcpmuxRow[], expanded, options);
  drewThoughts(view);
  drewLiveLine(view);
  return view;
}

/// `next` after `previous`, its one changed row at `index`, as the client marks it.
function after(previous: AcpmuxSnapshot, rows: AcpmuxRow[], index: number): AcpmuxSnapshot {
  const next = snapshot(rows);
  markOneRowChange(next.rows, previous.rows, index);
  return next;
}

const line = (rows: readonly AcpmuxRow[]) => rows.find((row) => row.id === LIVE_THINKING);

let flushes = 0;
beforeEach(() => {
  liveCallLine.reset();
  flushes = 0;
  liveCallLine.onFlush(() => (flushes += 1));
});
afterEach(() => {
  liveCallLine.reset();
  drewThoughts(undefined);
});

test("a hidden call's start names it on the line and its end returns the line to Thinking", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  const drawn = paneDraws(first);
  const drawnLine = line(drawn)!;
  expect(drawnLine.doing).toBeUndefined();

  const started = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  const start = callOnly(first, started);
  expect(start).toBeDefined();
  // The line the pane would draw from the newer snapshot, without the pane.
  const fresh = line(turnView(started.rows as AcpmuxRow[], new Set(), options))!;
  expect(start!.line.doing).toBe(fresh.doing);
  expect(start!.line.doing).toBeDefined();
  setLiveLine(start!.line);
  expect(lineCalledNow(drawnLine)).toBe(start!.line);
  // The transcript draws its rows again (a scroll): the same line, still ahead, no redraw.
  drewLiveLine(drawn);
  expect(flushes).toBe(0);

  const ended = after(started, [prompt, reply, work(3, [read("r1", "completed"), read("r2", "completed")])], 2);
  const end = callOnly(started, ended);
  expect(end).toBeDefined();
  expect(end!.line.doing).toBeUndefined();
  expect(end!.line.doing).toBe(line(turnView(ended.rows as AcpmuxRow[], new Set(), options))!.doing);
  setLiveLine(end!.line);
  expect(lineCalledNow(drawnLine)).toBe(end!.line);
});

test("an open fold redraws the pane: its rows show the calls", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  paneDraws(first, new Set([`${WORKED}-${prompt.id}`]));
  const started = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  expect(callOnly(first, started)).toBeUndefined();
});

test("opening the fold while the line is ahead draws the newest snapshot at once", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  paneDraws(first);
  const started = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  setLiveLine(callOnly(first, started)!.line);
  // The fold opens: the transcript draws the pane's older rows, without r2.
  transcriptDraws(first, new Set([`${WORKED}-${prompt.id}`]));
  expect(flushes).toBe(1);
  // The pane drew the newest; the next call is told from it.
  paneDraws(started);
  expect(lineCalledNow(line(turnView(started.rows as AcpmuxRow[], new Set(), options))!)).toBeDefined();
});

test("a call of an earlier turn, under a later prompt, redraws the pane", () => {
  const later: AcpmuxRow = { id: "p2", version: 1, at: 5_000, kind: "user", text: "And the tests" };
  const first = snapshot([prompt, work(1, [read("r1", "in_progress")]), later]);
  paneDraws(first);
  const ended = after(first, [prompt, work(2, [read("r1", "completed")]), later], 1);
  expect(callOnly(first, ended)).toBeUndefined();
});

test("a stale drawn line redraws the pane", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  transcriptDraws(first);
  // The pane drew another snapshot since the transcript shaped this one.
  liveCallLine.redraw(first);
  const started = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  expect(callOnly(first, started)).toBeUndefined();
  // A snapshot the bypass did not see in between.
  paneDraws(first);
  const other = snapshot(first.rows as AcpmuxRow[]);
  expect(callOnly(other, after(other, started.rows as AcpmuxRow[], 2))).toBeUndefined();
});

test("a call the line does not draw alone (a shell, an edit) redraws the pane", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  paneDraws(first);
  const shell = after(
    first,
    [prompt, reply, work(2, [read("r1", "completed"), read("s1", "in_progress", "execute")])],
    2,
  );
  expect(callOnly(first, shell)).toBeUndefined();
  const edit = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("e1", "in_progress", "edit")])], 2);
  expect(callOnly(first, edit)).toBeUndefined();
});

test("another bypass between calls moves the turn's rows on with it", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  paneDraws(first);
  const replied = after(first, [prompt, { ...reply, version: 2, text: "Looking now." }, first.rows[2]!], 1);
  liveCallLine.follow(first, replied);
  const started = after(
    replied,
    [prompt, replied.rows[1]!, work(2, [read("r1", "completed"), read("r2", "in_progress")])],
    2,
  );
  const start = callOnly(replied, started);
  expect(start).toBeDefined();
  expect(start!.line.doing).toBe(line(turnView(started.rows as AcpmuxRow[], new Set(), options))!.doing);
});

test("the activity row's own running flag and call count move with its calls, as the client sends them", () => {
  const counted = (version: number, items: AcpmuxActivity[]): AcpmuxRow =>
    ({
      ...work(version, items),
      toolCount: items.length,
      streaming: items.some((item) => item.tool?.status !== "completed"),
    }) as AcpmuxRow;
  const first = snapshot([prompt, reply, counted(1, [read("r1", "completed")])]);
  paneDraws(first);
  const started = after(first, [prompt, reply, counted(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  const start = callOnly(first, started);
  expect(start).toBeDefined();
  expect(start!.line.doing).toBe(line(turnView(started.rows as AcpmuxRow[], new Set(), options))!.doing);
  setLiveLine(start!.line);
  const ended = after(started, [prompt, reply, counted(3, [read("r1", "completed"), read("r2", "completed")])], 2);
  expect(callOnly(started, ended)).toBeDefined();
});

test("a hidden call that leaves the line's look as it is tells the line nothing new", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  const drawnLine = line(paneDraws(first))!;
  const started = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "in_progress")])], 2);
  const start = callOnly(first, started)!;
  let heard = 0;
  const stop = liveCallLineHeard.subscribe(() => (heard += 1));
  try {
    setLiveLine(start.line);
    expect(heard).toBe(1);
    // The same line at a later version (a call's status only, under one that runs on): no render.
    const same = { ...start.line, version: start.line.version + 1 } as AcpmuxRow;
    setLiveLine(same);
    expect(heard).toBe(1);
    // The line still reads the newest one at its next render.
    expect(lineCalledNow(drawnLine)).toBe(same);
    // A line that draws differently is heard.
    setLiveLine({ ...same, doing: "Reading src/r9.ts" } as AcpmuxRow);
    expect(heard).toBe(2);
  } finally {
    stop();
  }
});

test("once the pane's readers follow the rows store, a hidden shell's start moves only the line; an edit still redraws", () => {
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  paneDraws(first);
  const shell = after(
    first,
    [prompt, reply, work(2, [read("r1", "completed"), read("s1", "in_progress", "execute")])],
    2,
  );
  const start = callOnly(first, shell, true);
  expect(start).toBeDefined();
  expect(start!.line.doing).toBe(line(turnView(shell.rows as AcpmuxRow[], new Set(), options))!.doing);
  paneDraws(first);
  const edit = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("e1", "in_progress", "edit")])], 2);
  expect(callOnly(first, edit, true)).toBeUndefined();
});

test("with followed readers, a command's end under the turn's open fold moves only the row it changed", () => {
  const expanded = new Set([`${WORKED}-${prompt.id}`]);
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed"), read("s1", "in_progress", "execute")])]);
  const drew = paneDraws(first, expanded);
  const ended = after(
    first,
    [prompt, reply, work(2, [read("r1", "completed"), read("s1", "completed", "execute")])],
    2,
  );
  const call = callOnly(first, ended, true);
  expect(call).toBeDefined();
  const shaped = turnView(ended.rows as AcpmuxRow[], expanded, options);
  expect(call!.rows.length).toBeGreaterThan(0);
  for (const [from, to] of call!.rows) {
    expect(drew).toContain(from);
    expect(to).toEqual(shaped.find((row) => row.id === to.id)!);
  }
  setOpenRows(call!.rows);
  setLiveLine(call!.line);
  // The transcript told again of the rows it drew keeps them: those rows read the newer ones.
  drewLiveLine(drew);
  expect(flushes).toBe(0);
  // A pass that shapes the pane's older rows again draws the newest snapshot at once.
  transcriptDraws(first, expanded);
  expect(flushes).toBe(1);
});

test("with followed readers, a call under the turn's open fold moves only the rows it changed", () => {
  const expanded = new Set([`${WORKED}-${prompt.id}`]);
  const first = snapshot([prompt, reply, work(1, [read("r1", "completed")])]);
  const drew = paneDraws(first, expanded);
  const ended = after(first, [prompt, reply, work(2, [read("r1", "completed"), read("r2", "completed")])], 2);
  const call = callOnly(first, ended, true);
  const shaped = turnView(ended.rows as AcpmuxRow[], expanded, options);
  if (!call) {
    // The call drew a row of its own: the turn's rows change in number, so the pane draws them.
    expect(shaped.length).not.toBe(drew.length);
    return;
  }
  for (const [from, to] of call.rows) {
    expect(drew).toContain(from);
    expect(shaped.find((row) => row.id === to.id)).toEqual(to);
  }
  expect(call.rows.length).toBeGreaterThan(0);
  // Unfollowed readers still redraw the pane for it.
  paneDraws(first, expanded);
  expect(callOnly(first, ended)).toBeUndefined();
});
