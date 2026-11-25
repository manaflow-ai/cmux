// A turn that is one long call (a build, a test run, a watcher) with the reply streaming beside it keeps its held
// records bounded (direct.ts `shedOlderHeld`): the call's row and the reply's change with every record, so each spans
// every cut, and the cut went back to the turn's start. The chat shed once in 20,000 records and held every record
// after it (29,216 under the typing bench's heavy load). Now the call's oldest output lines go with their records and
// the row stays, marked as cut (`earlierOutput`); the reply keeps its text; and scrolling up reads the lines back
// through the older-page path, in order, so nothing is lost for the reader.
// Leo, 2026-11-14: "the dream is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./direct";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const TURN_ID = "t-build";
const CALL = "build-1";
const STARTED_AT = 1_700_000_000_020;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

function inbound(sessionId: string, seq: number, update: Record<string, unknown>) {
  return {
    sessionId,
    seq,
    at: 1_700_000_000_000 + seq * 10,
    dir: "in",
    kind: update.sessionUpdate,
    msg: { method: "session/update", params: { sessionId, update } },
  } as EventRecord;
}
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: 1_700_000_000_000 + seq * 10, dir: "mux", kind, msg }) as EventRecord;

/// One output line of the call, printed by record `seq`.
const line = (seq: number) => `[${String(seq).padStart(6, "0")}] compiling module${seq % 97}.ts ok\n`;
/// One chunk of the reply, streamed by record `seq`.
const word = (seq: number) => `w${seq} `;

/// The turn's opening records: its prompt, its start, the one call that runs the whole turn.
function opening(sessionId: string, seq: number): EventRecord | undefined {
  if (seq === 1) return mux(sessionId, seq, "user_message", { text: "build it", promptId: "p-build" });
  if (seq === 2) return mux(sessionId, seq, "turn_started", { promptId: "p-build", turnId: TURN_ID });
  if (seq === 3)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call",
      toolCallId: CALL,
      kind: "execute",
      title: "Run bun run build",
      status: "in_progress",
      rawInput: { command: "bun run build" },
    });
  return undefined;
}

/// The typing bench's heavy load (composer-typing.bench.ts `--stream 60 --tool-lines 2000`): a line per record
/// (`_meta.terminal_output.data`, the append form pi sends), with a reply chunk every fourth record.
function appendStream(sessionId: string, seq: number): EventRecord {
  const open = opening(sessionId, seq);
  if (open) return open;
  if (seq % 4 === 0)
    return inbound(sessionId, seq, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: word(seq) },
    });
  return inbound(sessionId, seq, {
    sessionUpdate: "tool_call_update",
    toolCallId: CALL,
    status: "in_progress",
    _meta: { terminal_output: { data: line(seq) } },
  });
}

/// The mock host's load (mock.ts `streamLoadTurn` with `toolLinesPerSecond`): every other record the call's whole
/// output so far (acpmux's form), between reply chunks. Built incrementally: records are read in order.
function replaceStream() {
  let output = "";
  let through = 3;
  return (sessionId: string, seq: number): EventRecord => {
    const open = opening(sessionId, seq);
    if (open) return open;
    if (seq % 2 === 0)
      return inbound(sessionId, seq, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: word(seq) },
      });
    for (; through < seq; through += 1) if ((through + 1) % 2 === 1) output += `${through + 1}\n`;
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call_update",
      toolCallId: CALL,
      status: "in_progress",
      content: [{ type: "content", content: { type: "text", text: output } }],
    });
  };
}

type Item = { tool?: { id: string; output?: string; earlierOutput?: true } };
type Row = { id: string; kind: string; text?: string; items?: Item[] };
type Pane = {
  events: EventRecord[];
  turnOpen: boolean;
  firstSeq?: number;
  historyExhausted: boolean;
  rows: Map<string, Row>;
  splits: Map<string, { aside: EventRecord[] }>;
};

async function openChat(stream: (sessionId: string, seq: number) => EventRecord) {
  const { AcpmuxDirectClient, HELD_RECORDS } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const state = { target: "", total: 0 };
  const running = { status: "running", indicator: "working", turn: { turnId: TURN_ID, startedAt: STARTED_AT } };
  let socket: { deliver: (message: unknown) => void } | undefined;
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, any>;
          state.target = params.sessionId;
          return {
            ...result,
            session: { ...result.session, ...running },
            events: [],
            hasMore: false,
            lastSeq: 0,
            pageThrough: 0,
            turnOpener: null,
          };
        }
        if (method === "_acpmux/watch") {
          const result = (await answer(method, params)) as { sessions: Record<string, unknown>[] };
          return {
            ...result,
            sessions: result.sessions.map((session) =>
              session.sessionId === mockHost.sessionId ? { ...session, ...running } : session,
            ),
          };
        }
        if (method === "_acpmux/events" && params.sessionId === state.target && params.beforeSeq !== undefined) {
          const limit = Number(params.limit ?? 400);
          const kinds: string[] | undefined = params.kinds?.includes("transcript") ? undefined : params.kinds;
          const events: EventRecord[] = [];
          for (let seq = params.beforeSeq - 1; seq >= 1 && events.length < limit; seq -= 1) {
            const event = stream(state.target, seq);
            if (!kinds || kinds.includes(event.kind)) events.unshift(event);
          }
          return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq: state.total };
        }
        if (method === "_acpmux/events" && params.sessionId === state.target) {
          const events: EventRecord[] = [];
          for (let seq = Number(params.afterSeq ?? 0) + 1; seq <= state.total && events.length < 5_000; seq += 1)
            events.push(stream(state.target, seq));
          return { events, hasMore: false, lastSeq: state.total };
        }
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const pane = client as unknown as Pane;
  client.setFollowing(true);
  expect(await settle(() => state.target !== "", 10_000)).toBe(true);
  for (let index = 0; index < 20; index += 1) await tick();
  // Every refold of the held records from here on: a shed lets go in place and folds nothing again.
  let rebuilds = 0;
  const refold = client as unknown as { rebuild: (...args: unknown[]) => void };
  const rebuild = refold.rebuild;
  refold.rebuild = function (this: unknown, ...args: unknown[]) {
    rebuilds += 1;
    return rebuild.apply(this, args);
  };
  const deliver = () => {
    state.total += 1;
    socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: stream(state.target, state.total) });
  };
  const toolRow = () => [...pane.rows.values()].find((row) => row.items?.some((item) => item.tool?.id === CALL));
  const tool = () => toolRow()?.items?.find((item) => item.tool?.id === CALL)?.tool;
  const replies = () => [...pane.rows.values()].filter((row) => row.kind === "assistant");
  const close = () => {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  };
  return { client, pane, state, deliver, flush, tool, toolRow, replies, close, rebuilds: () => rebuilds, HELD_RECORDS };
}

/// Streams `count` records, watching the held count after each, and the heap every 2,000.
async function streamTurn(chat: Awaited<ReturnType<typeof openChat>>, count: number) {
  let sheds = 0;
  let oldest = chat.pane.events[0]?.seq ?? 1;
  let heldMax = 0;
  const heap: number[] = [];
  for (let index = 0; index < count; index += 1) {
    chat.deliver();
    heldMax = Math.max(heldMax, chat.pane.events.length);
    const first = chat.pane.events[0]?.seq ?? 1;
    if (first > oldest) {
      sheds += 1;
      oldest = first;
    }
    if (index % 50 !== 49) continue;
    await tick();
    chat.flush();
    if (index % 2_000 === 1_999) {
      Bun.gc(true);
      heap.push(process.memoryUsage().heapUsed);
    }
  }
  return { sheds, heldMax, heap };
}

const mb = (bytes: number) => (bytes / 1024 / 1024).toFixed(1);

test("a 20,000-record turn that is one call keeps its held records bounded, and drops its oldest lines", async () => {
  const chat = await openChat(appendStream);
  try {
    for (let seq = 1; seq <= 3; seq += 1) chat.deliver();
    const { sheds, heldMax, heap } = await streamTurn(chat, 20_000);
    const total = chat.state.total;
    const tool = chat.tool();
    const lines = tool?.output?.split("\n").filter(Boolean).length ?? 0;
    console.log(
      `one-call(append) streamed=${total} sheds=${sheds} held_max=${heldMax} held_final=${chat.pane.events.length} ` +
        `aside=${[...chat.pane.splits.values()].reduce((sum, split) => sum + split.aside.length, 0)} ` +
        `tool_lines=${lines} heap_max_mb=${mb(Math.max(...heap))} heap_final_mb=${mb(heap.at(-1) ?? 0)} ` +
        `rebuilds=${chat.rebuilds()}`,
    );
    expect(sheds).toBeGreaterThan(3);
    expect(heldMax).toBeLessThanOrEqual(chat.HELD_RECORDS + 1);
    expect(chat.rebuilds()).toBe(0);
    // The call's row stays, marked as cut, its output the newest lines in order, as many as the records left hold.
    expect(tool?.earlierOutput).toBe(true);
    expect(lines).toBeLessThanOrEqual(chat.HELD_RECORDS);
    let full = "";
    for (let seq = 4; seq <= total; seq += 1) if (seq % 4 !== 0) full += line(seq);
    expect(full.endsWith(tool!.output!)).toBe(true);
    expect(tool!.output!.endsWith(line(total % 4 === 0 ? total - 1 : total))).toBe(true);
    // The reply streaming beside it keeps all of its text: one row, every chunk in order.
    let text = "";
    for (let seq = 4; seq <= total; seq += 1) if (seq % 4 === 0) text += word(seq);
    expect(chat.replies().map((row) => row.text)).toEqual([text]);
    expect(chat.pane.turnOpen).toBe(true);
  } finally {
    chat.close();
  }
}, 300_000);

test("a turn that is one call sending its whole output with each update keeps its held records bounded", async () => {
  const chat = await openChat(replaceStream());
  try {
    for (let seq = 1; seq <= 3; seq += 1) chat.deliver();
    const { sheds, heldMax, heap } = await streamTurn(chat, 9_000);
    const total = chat.state.total;
    const tool = chat.tool();
    console.log(
      `one-call(whole) streamed=${total} sheds=${sheds} held_max=${heldMax} held_final=${chat.pane.events.length} ` +
        `heap_max_mb=${mb(Math.max(...heap))} heap_final_mb=${mb(heap.at(-1) ?? 0)} rebuilds=${chat.rebuilds()}`,
    );
    expect(sheds).toBeGreaterThan(1);
    expect(heldMax).toBeLessThanOrEqual(chat.HELD_RECORDS + 1);
    expect(chat.rebuilds()).toBe(0);
    // Its newest update carries all of it: the row keeps the whole output, not marked as cut.
    let full = "";
    for (let seq = 5; seq <= total; seq += 2) full += `${seq}\n`;
    expect(tool?.output).toBe(full);
    expect(tool?.earlierOutput).toBeUndefined();
  } finally {
    chat.close();
  }
}, 300_000);

test("scrolling up a turn that is one call brings its dropped output lines back, in order", async () => {
  const chat = await openChat(appendStream);
  try {
    for (let seq = 1; seq <= 3; seq += 1) chat.deliver();
    const { sheds } = await streamTurn(chat, 12_000);
    expect(sheds).toBeGreaterThan(1);
    const total = chat.state.total;
    let full = "";
    let text = "";
    for (let seq = 4; seq <= total; seq += 1)
      if (seq % 4 === 0) text += word(seq);
      else full += line(seq);
    expect(chat.tool()?.earlierOutput).toBe(true);
    // The reader scrolls up: each older page (the short one a chat at rest reads) lands above the held records.
    chat.client.setFollowing(false);
    const failures: string[] = [];
    let pages = 0;
    while ((chat.pane.firstSeq ?? 1) > 1 && pages < 100) {
      const from = chat.pane.firstSeq;
      await chat.client.loadOlder(undefined, false, false);
      chat.flush();
      pages += 1;
      if (chat.pane.firstSeq === from) break;
      // After each page: one row for the call, its output a whole run of the newest lines, never a line twice.
      const output = chat.tool()?.output ?? "";
      if (!full.endsWith(output)) failures.push(`page ${pages}: the output is not the newest lines in order`);
      if (
        chat
          .replies()
          .map((row) => row.text)
          .join("|") !== text
      )
        failures.push(`page ${pages}: the reply is not its text once`);
    }
    console.log(`one-call(scroll-up) pages=${pages} first=${chat.pane.firstSeq} failures=${failures.length}`);
    for (const failure of failures.slice(0, 8)) console.log(failure);
    expect(failures).toEqual([]);
    expect(chat.pane.firstSeq).toBe(1);
    expect(chat.tool()?.output).toBe(full);
    expect(chat.tool()?.earlierOutput).toBeUndefined();
    expect(
      [...chat.pane.rows.values()].filter((row) => row.items?.some((item) => item.tool?.id === CALL)),
    ).toHaveLength(1);
    expect(chat.replies().map((row) => row.text)).toEqual([text]);
  } finally {
    chat.close();
  }
}, 300_000);

/// Lands an older page above the held records as loadOlder's `publish` does for a page inside the turn (`foldOlder`):
/// the page folds incrementally above them.
function foldPage(chat: Awaited<ReturnType<typeof openChat>>, page: EventRecord[]) {
  const pane = chat.client as unknown as { events: EventRecord[]; foldOlder: (older: EventRecord[]) => void };
  pane.events = [...page, ...pane.events].sort((a, b) => a.seq - b.seq);
  pane.foldOlder(page);
  chat.flush();
}

/// A 12,000-record one-call turn, shed with its call's oldest lines dropped; the full output and reply it streamed.
async function shedTurn(chat: Awaited<ReturnType<typeof openChat>>) {
  for (let seq = 1; seq <= 3; seq += 1) chat.deliver();
  const { sheds } = await streamTurn(chat, 12_000);
  expect(sheds).toBeGreaterThan(1);
  const total = chat.state.total;
  let full = "";
  let text = "";
  for (let seq = 4; seq <= total; seq += 1)
    if (seq % 4 === 0) text += word(seq);
    else full += line(seq);
  expect(chat.tool()?.earlierOutput).toBe(true);
  chat.client.setFollowing(false);
  return { full, text, first: chat.pane.events[0]!.seq };
}

const callRows = (chat: Awaited<ReturnType<typeof openChat>>) =>
  [...chat.pane.rows.values()].filter((row) => row.items?.some((item) => item.tool?.id === CALL));

test("an older page holding the prompt, then the call's opening record and lines, puts the lines back on its one row", async () => {
  const chat = await openChat(appendStream);
  try {
    const { full, first } = await shedTurn(chat);
    // The page folding the turn's prompt first clears the call ids it knows; the call's opening record and its oldest
    // lines still fold into the page's row of the call, never a second row whose lines the page then drops.
    const page: EventRecord[] = [];
    for (let seq = 1; seq < first; seq += 1) page.push(appendStream(chat.state.target, seq));
    foldPage(chat, page);
    expect(callRows(chat)).toHaveLength(1);
    expect(chat.tool()?.output).toBe(full);
    expect(chat.tool()?.earlierOutput).toBeUndefined();
  } finally {
    chat.close();
  }
}, 300_000);

test("a page that reaches below the call's opening record without holding it keeps the call's mark and that record", async () => {
  const chat = await openChat(appendStream);
  try {
    const { full, first } = await shedTurn(chat);
    // acpmux can leave a record out of a page: this one reaches the turn start but not the call's opening record.
    const page: EventRecord[] = [];
    for (let seq = 2; seq < first; seq += 1) if (seq !== 3) page.push(appendStream(chat.state.target, seq));
    foldPage(chat, page);
    expect(callRows(chat)).toHaveLength(1);
    expect(chat.tool()?.output).toBe(full);
    // The call's start is still unread: the row stays marked, and its opening record stays held aside for a refold.
    expect(chat.tool()?.earlierOutput).toBe(true);
    expect([...chat.pane.splits.values()].some((split) => split.aside.some((event) => event.seq === 3))).toBe(true);
    // A full refold of what is held draws the call's row once, every line in order.
    (chat.client as unknown as { rebuildKeepingLiveState: () => void }).rebuildKeepingLiveState();
    chat.flush();
    expect(callRows(chat)).toHaveLength(1);
    expect(chat.tool()?.output).toBe(full);
  } finally {
    chat.close();
  }
}, 300_000);
