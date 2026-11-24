// A turn that never ends stays open, as the person sees it, through every shed of its oldest records (direct.ts
// `shedOlderHeld`): the pane's turn stays open and the chat still says it works (Stop, the "Working for" clock), the
// newest row is still the reply it streams into, and a message sent then waits behind the running turn (the queue),
// never as a prompt that starts a turn of its own. The host's summaries say what a real daemon says while the turn
// runs: `running`, with the turn it holds open.
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

/// Records per message: its streamed chunks, then a tool call with a streamed output.
const MESSAGE = 25;
const OUTPUT = "x".repeat(200);
const TURN_ID = "t-forever";
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
const call = (sessionId: string, seq: number, id: string, status?: string, output?: string) =>
  inbound(sessionId, seq, {
    sessionUpdate: status === "start" ? "tool_call" : "tool_call_update",
    toolCallId: id,
    ...(status === "start" ? { kind: "execute", title: `run ${id}`, status: "in_progress" } : {}),
    ...(status && status !== "start" ? { status } : {}),
    ...(output ? { content: [{ type: "content", content: { type: "text", text: output } }] } : {}),
  });

/// One turn that never ends: its prompt, its start, then messages and tool calls forever, with a steer now and then.
function neverEnding(sessionId: string, seq: number): EventRecord {
  if (seq === 1) return mux(sessionId, seq, "user_message", { text: "coordinate", promptId: "p-open" });
  if (seq === 2) return mux(sessionId, seq, "turn_started", { promptId: "p-open", turnId: TURN_ID });
  const phase = seq % MESSAGE;
  const message = Math.floor(seq / MESSAGE);
  if (phase === 0 && message % 40 === 0)
    return mux(sessionId, seq, "user_message", { text: `steer ${seq}`, steer: true, turnId: TURN_ID });
  if (phase === MESSAGE - 3) return call(sessionId, seq, `t${message}`, "start");
  if (phase === MESSAGE - 2) return call(sessionId, seq, `t${message}`, undefined, `${OUTPUT} ${message}`);
  if (phase === MESSAGE - 1) return call(sessionId, seq, `t${message}`, "completed", `${OUTPUT} ${message}`);
  return inbound(sessionId, seq, {
    sessionUpdate: "agent_message_chunk",
    messageId: `m${message}`,
    content: { type: "text", text: `w${seq} ` },
  });
}

type Row = { id: string; kind: string; text?: string; streaming?: boolean };
type Snapshot = { rows: Row[]; isWorking?: boolean; queue?: { id: string }[] };
type Pane = {
  events: EventRecord[];
  turnOpen: boolean;
  streamingAssistant?: string;
};

async function throughSheds(stream: (sessionId: string, seq: number) => EventRecord, count: number) {
  const { AcpmuxDirectClient, HELD_RECORDS } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  let target = "";
  let total = 0;
  // What a daemon running the turn lists: `running`, the turn it holds open.
  const running = { status: "running", indicator: "working", turn: { turnId: TURN_ID, startedAt: STARTED_AT } };
  const prompts: { promptId?: string; steer?: boolean }[] = [];
  const held: (() => void)[] = [];
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
          target = params.sessionId;
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
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq !== undefined) {
          const limit = Number(params.limit ?? 400);
          const kinds: string[] | undefined = params.kinds?.includes("transcript") ? undefined : params.kinds;
          const events: EventRecord[] = [];
          for (let seq = params.beforeSeq - 1; seq >= 1 && events.length < limit; seq -= 1) {
            const event = stream(target, seq);
            if (!kinds || kinds.includes(event.kind)) events.unshift(event);
          }
          return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq: total };
        }
        if (method === "_acpmux/events" && params.sessionId === target) {
          const events: EventRecord[] = [];
          for (let seq = Number(params.afterSeq ?? 0) + 1; seq <= total && events.length < 5_000; seq += 1)
            events.push(stream(target, seq));
          return { events, hasMore: false, lastSeq: total };
        }
        // The daemon holds the prompt behind the running turn: it answers once that prompt runs, which in a turn
        // that never ends is not before the test is done.
        if (method === "session/prompt") {
          prompts.push({ promptId: params._meta?.acpmux?.promptId, steer: params._meta?.acpmux?.steer === true });
          return new Promise((resolve) => held.push(() => resolve({})));
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
  let snapshot: Snapshot = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as Snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const pane = client as unknown as Pane;
  try {
    client.setFollowing(true);
    expect(await settle(() => target !== "", 10_000)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    const deliver = (seq: number) =>
      socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: stream(target, seq) });
    // A summary the daemon sends as the turn runs on (`session_changed`): still running, the same turn.
    const summarize = () =>
      socket!.deliver({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { kind: "updated", session: { sessionId: target, ...running } },
      });
    let sheds = 0;
    let oldest = 1;
    const failures: string[] = [];
    for (let index = 0; index < count; index += 1) {
      total += 1;
      deliver(total);
      if (index % 50 !== 49) continue;
      if (index % 500 === 499) summarize();
      await tick();
      flush();
      const first = pane.events[0]?.seq ?? 1;
      if (first <= oldest) continue;
      oldest = first;
      sheds += 1;
      // Right after the shed, as the person sees the chat.
      const where = `shed ${sheds} at seq ${total}`;
      if (!pane.turnOpen) failures.push(`${where}: the pane's turn closed`);
      if (snapshot.isWorking !== true) failures.push(`${where}: the snapshot says not working (no Stop)`);
      // The reply streams on: after the next chunk, the newest row is the streaming reply the pane writes into.
      let next = total + 1;
      while (stream(target, next).kind !== "agent_message_chunk") next += 1;
      while (total < next) {
        total += 1;
        deliver(total);
      }
      await tick();
      flush();
      const live = snapshot.rows.at(-1);
      if (live?.kind !== "assistant" || live.streaming !== true || pane.streamingAssistant !== live.id)
        failures.push(`${where}: the newest row is not the streaming reply (${live?.kind} ${String(live?.streaming)})`);
      if (snapshot.isWorking !== true) failures.push(`${where}: not working once the reply streams on`);
      // A message sent now goes behind the running turn, not as a prompt that opens one.
      const promptId = `p-queued-${sheds}`;
      void client
        .send(`later ${sheds}`, [], promptId, undefined, `ticket-${promptId}`, false)
        .catch((error: unknown) => failures.push(`${where}: the send failed: ${String(error)}`));
      if (!(await settle(() => prompts.some((prompt) => prompt.promptId === promptId), 2_000)))
        failures.push(`${where}: a message sent then never reached the host`);
      flush();
      if (!(snapshot.queue ?? []).some((entry) => entry.id === promptId))
        failures.push(`${where}: a message sent then did not wait behind the running turn`);
      if (snapshot.rows.some((row) => row.kind === "user" && row.text === `later ${sheds}`))
        failures.push(`${where}: a message sent then drew as a prompt of its own`);
    }
    console.log(
      `open-turn streamed=${total} sheds=${sheds} held=${pane.events.length} working=${String(snapshot.isWorking)} failures=${failures.length}`,
    );
    for (const failure of failures.slice(0, 8)) console.log(failure);
    expect(sheds).toBeGreaterThan(2);
    expect(pane.events.length).toBeLessThanOrEqual(HELD_RECORDS);
    expect(failures).toEqual([]);
  } finally {
    for (const answer of held.splice(0)) answer();
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}

test(
  "a turn that never ends stays open through every shed, and a send waits behind it",
  () => throughSheds(neverEnding, 12_000),
  300_000,
);

/// One turn that is one call for its whole length (a build, a watcher): a line of output per record, the append form
/// pi sends (`_meta.terminal_output.data`), with the reply streaming beside it, as the typing bench's heavy load does.
function oneCall(sessionId: string, seq: number): EventRecord {
  if (seq === 1) return mux(sessionId, seq, "user_message", { text: "build it", promptId: "p-open" });
  if (seq === 2) return mux(sessionId, seq, "turn_started", { promptId: "p-open", turnId: TURN_ID });
  if (seq === 3)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call",
      toolCallId: "build",
      kind: "execute",
      title: "Run bun run build",
      status: "in_progress",
      rawInput: { command: "bun run build" },
    });
  if (seq % 4 === 0)
    return inbound(sessionId, seq, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: `w${seq} ` },
    });
  return inbound(sessionId, seq, {
    sessionUpdate: "tool_call_update",
    toolCallId: "build",
    status: "in_progress",
    _meta: { terminal_output: { data: `line ${seq}\n` } },
  });
}

// The call's row and the reply beside it span every cut: the sheds that keep them across it (`planSplits`) keep the
// turn open as the person sees it, its newest row the reply it streams into, and a send behind it.
test(
  "a turn that is one long call stays open through every shed, and a send waits behind it",
  () => throughSheds(oneCall, 16_000),
  300_000,
);

// The composer typing bench streams its load through the mock host (`streamLoadTurn`): the same stream, through the
// same client, keeps its turn open after each shed. (A send is not checked here: this mock lists its queue without a
// prompt it never took, which drops the pane's queued entry on its next summary; the test above checks the send
// against a host that takes it.)
test("the mock host's streaming load (the typing bench's) keeps its turn open through every shed", async () => {
  const { AcpmuxDirectClient, HELD_RECORDS } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  let snapshot: Snapshot = { rows: [] };
  let pane: Pane | undefined;
  let mock!: { close: () => void; streamLoadTurn: (target: string, options: Record<string, number>) => unknown };
  let deltas = 0;
  let sheds = 0;
  let oldest = Infinity;
  const failures: string[] = [];
  // The bench paces the stream on a timer; here each delta waits one task, and every 50 the chat is looked at.
  const delay = async () => {
    deltas += 1;
    await tick();
    if (deltas % 50 !== 0 || !pane) return;
    flush();
    const first = pane.events[0]?.seq ?? 0;
    if (oldest !== Infinity && first > oldest) {
      sheds += 1;
      const where = `shed ${sheds} at delta ${deltas}`;
      if (!pane.turnOpen) failures.push(`${where}: the pane's turn closed`);
      if (snapshot.isWorking !== true) failures.push(`${where}: the snapshot says not working (no Stop)`);
      const live = snapshot.rows.at(-1);
      if (live?.kind !== "assistant" || live.streaming !== true)
        failures.push(`${where}: the newest row is not the streaming reply (${live?.kind} ${String(live?.streaming)})`);
    }
    oldest = first;
    if (sheds >= 4 || deltas >= 20_000) mock.close();
  };
  class Bench extends MockAcpmuxSocket {
    constructor() {
      super(delay);
      mock = this as unknown as typeof mock;
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as Snapshot),
    undefined,
    () => new Bench() as unknown as WebSocket,
  );
  pane = client as unknown as Pane;
  try {
    client.setFollowing(true);
    expect(await settle(() => pane!.events.length > 0, 10_000)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    oldest = pane.events[0]?.seq ?? 0;
    await mock.streamLoadTurn(mockHost.sessionId!, { seconds: 600, chunkChars: 32, chunkMs: 1, toolEvery: 30 });
    console.log(`bench-load deltas=${deltas} sheds=${sheds} held=${pane.events.length} failures=${failures.length}`);
    for (const failure of failures.slice(0, 8)) console.log(failure);
    expect(sheds).toBeGreaterThan(1);
    expect(pane.events.length).toBeLessThanOrEqual(HELD_RECORDS + 50);
    expect(failures).toEqual([]);
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}, 300_000);
