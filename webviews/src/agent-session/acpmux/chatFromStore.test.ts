// A chat drawn from the row store through the pane's client (direct.ts, rows/chatSource.ts), against
// the mock daemon with the hold (`attach-hold-v1`) and a host that serves `chat.rows.*`: the switch
// is asked before the v1 attach, which is the hold; the store's rows are the snapshot's; a text op
// draws once and runs none of v1's rebuild; a chat left and opened again draws its kept window
// before any change, and its first window replaces it in one step. With the chat list still out, the
// open asks the switch and draws from its attach alone (decision 289). The recording's rows are of kind
// `assistant`, which the adapter draws nothing of; here they are read as `text` rows.
import { afterAll, beforeAll, expect, test, beforeEach } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { HOLD_KINDS } from "./rows/holdKinds";
import { resetChatRowsReceiver, listenForChatRows } from "./rows/receiver";
import type { Lanes } from "./schedule";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.cmuxAcpmuxMockCapabilities = ["attach-hold-v1"];
});
afterAll(async () => {
  delete scope.cmuxAcpmuxMockCapabilities;
  (await import("./native")).setNativeHost(undefined);
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});
/// The document's receiver applies each batch at once, in the receiving task: these tests are about
/// what a batch draws, not when (rows/receiver.test.ts covers the frame pacing).
beforeEach(() => {
  const slice = { timeLeft: () => Number.POSITIVE_INFINITY, shouldYield: () => false };
  const lanes: Lanes = {
    frame: (_key, fn) => void fn(slice),
    idle: (_key, fn) => void fn(slice),
    inputPending: () => false,
    yield: () => Promise.resolve(),
    flush: () => {},
    dispose: () => {},
  };
  listenForChatRows(lanes);
});

const settle = async (done: () => boolean) => {
  // timeout: a mock daemon and host answer in microtasks; past 2 s a wait names what it waited on, not a hang.
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

const FIXTURES = `${import.meta.dir}/../../../../Packages/macOS/CmuxNext/Tests/Fixtures/AgentChatStream`;
/// The chat recording's change strings by step, for sid `sid`, its rows read as text rows.
function recorded(step: string, sid: string): string[] {
  const out: string[] = [];
  let inside = false;
  for (const text of readFileSync(`${FIXTURES}/chat.jsonl`, "utf8").split("\n")) {
    if (!text.trim()) continue;
    const line = JSON.parse(text) as unknown;
    if (line && typeof line === "object" && "step" in line) inside = line.step === step;
    else if (inside && typeof line === "string")
      out.push(line.replaceAll('"kind":"assistant"', '"kind":"text"').replaceAll('"rows.1"', JSON.stringify(sid)));
  }
  return out;
}

type Row = { id: string; kind: string };
type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

test("a chat on the store: switch first, the hold, its rows, and its kept window", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const [a, b] = mockSessions.map((session) => session.sessionId);
  // Daemon requests and host posts, in the order the page made them.
  const asked: { to: string; method: string; params: any }[] = [];
  const sids = new Map<string, string>();
  // While set, the host answers an open only once it settles.
  let gate: Promise<void> | undefined;
  setNativeHost(async (method, params) => {
    asked.push({ to: "host", method, params });
    if (method !== "chat.rows.open") return null;
    sids.set(String(params.chat), String(params.sid));
    await gate;
    return { sid: params.sid };
  });
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ to: "daemon", method, params });
        if (method !== "_acpmux/attach" || params.hold !== true) return answer(method, params);
        const page = (await answer(method, { sessionId: params.sessionId })) as any;
        return { session: page.session, lastSeq: page.lastSeq, presence: {}, readThrough: null, hold: true };
      };
    }
  }
  let snapshots = 0;
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    (snapshot) => {
      snapshots += 1;
      rows = snapshot.rows as Row[];
    },
    undefined,
    () => new Held() as unknown as WebSocket,
  );
  const direct = client as any;
  // As the host calls it: the document's receiver, which the client installed before its first open.
  const feed = (changes: string[]) =>
    (globalThis as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows!.receive({ batch: 1, changes });
  try {
    await settle(() => asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a));
    // The switch is asked, then the v1 attach is the hold: no page, no log read.
    const open = asked.findIndex((ask) => ask.method === "chat.rows.open" && ask.params.chat === a);
    const attach = asked.findIndex((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a);
    expect(open).toBeGreaterThanOrEqual(0);
    expect(open).toBeLessThan(attach);
    expect(asked[attach]!.params).toEqual({
      sessionId: a,
      hold: true,
      eventStream: true,
      kinds: [...HOLD_KINDS],
      visible: expect.any(Boolean),
    });

    // The store's window is the snapshot's rows.
    feed(recorded("window", sids.get(a)!));
    feed(recorded("ops", sids.get(a)!).slice(0, 2));
    await settle(() => rows.some((row) => row.id === "row-12"));
    expect(rows.map((row) => row.id)).toEqual(Array.from({ length: 12 }, (_, n) => `row-${n + 1}`));

    // One text op: one snapshot, and none of v1's rebuild or reduce.
    let v1 = 0;
    for (const name of ["rebuild", "reduce"]) {
      const real = direct[name].bind(direct);
      direct[name] = (...args: unknown[]) => {
        v1 += 1;
        return real(...args);
      };
    }
    const drawn = snapshots;
    const shown = rows;
    feed(recorded("ops", sids.get(a)!).filter((line) => line.includes('"op":"text"')));
    expect(snapshots).toBe(drawn + 1);
    expect(v1).toBe(0);
    expect(rows.filter((row, at) => row !== shown[at]).map((row) => row.id)).toEqual(["row-12"]);

    // Another chat: the first is closed, keeping its settled rows (row 12 is still open).
    await client.select(b!);
    expect(asked.some((ask) => ask.method === "chat.rows.close" && ask.params.sid === sids.get(a))).toBe(true);
    feed(recorded("window", sids.get(b!)!));

    // Back to the first: its kept window is drawn before any change, and stays while its open is out.
    let answer = () => {};
    gate = new Promise((resolve) => (answer = resolve));
    const back = client.select(a!);
    expect(rows.map((row) => row.id)).toEqual(Array.from({ length: 11 }, (_, n) => `row-${n + 1}`));
    const kept = rows;
    await settle(() => asked.at(-1)?.method === "chat.rows.open" && asked.at(-1)?.params.chat === a);
    answer();
    await back;
    expect(rows).toBe(kept);
    // Its first window replaces it in one step.
    const before = snapshots;
    feed(recorded("window", sids.get(a)!));
    expect(snapshots).toBe(before + 1);
    expect(rows.map((row) => row.id)).toEqual(Array.from({ length: 11 }, (_, n) => `row-${n + 1}`));
    expect(rows).not.toBe(kept);

    // Left for no chat: its sub on the store is closed, not kept open behind the pane.
    direct.leave();
    await settle(() => asked.some((ask) => ask.method === "chat.rows.close" && ask.params.sid === sids.get(a)));
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});

/// A daemon with the hold whose chat list never answers, and a host that answers `chat.rows.open`
/// with `open`: the open's chat comes from its early attach alone (decision 289). With `list`, the
/// list answers once it settles.
async function listOut(open: (params: any) => Promise<unknown>, list?: Promise<void>) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const a = mockSessions[0]!.sessionId;
  const asked: { to: string; method: string; params: any }[] = [];
  setNativeHost(async (method, params) => {
    asked.push({ to: "host", method, params });
    return method === "chat.rows.open" ? open(params) : null;
  });
  class ListOut extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ to: "daemon", method, params });
        if (method === "_acpmux/watch") return list ? list.then(() => answer(method, params)) : new Promise(() => {});
        if (method !== "_acpmux/attach" || params.hold !== true) return answer(method, params);
        const page = (await answer(method, { sessionId: params.sessionId })) as any;
        return { session: page.session, lastSeq: page.lastSeq, presence: {}, readThrough: null, hold: true };
      };
    }
  }
  let rows: Row[] = [];
  const connecting = AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    (snapshot) => {
      rows = snapshot.rows as Row[];
    },
    undefined,
    () => new ListOut() as unknown as WebSocket,
  ).then((client) => client as any);
  const hostPosts = () => asked.filter((ask) => ask.to === "host" && ask.method.startsWith("chat.rows."));
  const attaches = () => asked.filter((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a);
  return { a, b: mockSessions[1]!.sessionId, asked, connecting, rows: () => rows, hostPosts, attaches };
}

test("an early attach the open dropped while its switch was out, for a chat no longer shown, is never sent", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  // The client as its open asks the attach with the list, before `connect` answers: the pick below
  // lands while that open is still out, as a person's click can.
  const proto = AcpmuxDirectClient.prototype as any;
  const askEarly = proto.askEarly;
  let opening: any;
  const caught = (client: unknown) => (opening = client);
  proto.askEarly = function (this: unknown) {
    caught(this);
    return askEarly.call(this);
  };
  let listed = () => {};
  const list = new Promise<void>((resolve) => (listed = resolve));
  let answerA = () => {};
  const gateA = new Promise<void>((resolve) => (answerA = resolve));
  // The first open (the early attach's switch, for the tab's chat) waits on `answerA`.
  let first = true;
  const run = await listOut(async (params) => {
    if (first) {
      first = false;
      await gateA;
    }
    return { sid: params.sid };
  }, list);
  try {
    await settle(() => run.hostPosts().some((post) => post.method === "chat.rows.open" && post.params.chat === run.a));
    proto.askEarly = askEarly;
    // Another chat is picked with the switch for the first still out (well within `OPEN_ANSWER_MS`);
    // then the list answers, and the open drops the early attach of the chat no longer shown.
    const picking = opening.select(run.b);
    listed();
    await settle(() => opening.selectedSessionId === run.b && !opening.earlyAttach);
    answerA();
    await picking;
    await run.connecting;
    for (let turn = 0; turn < 10; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(run.attaches()).toHaveLength(0);
  } finally {
    proto.askEarly = askEarly;
    opening?.close?.();
    resetChatRowsReceiver();
  }
});

test("with the list still out, a host without chat.rows: the chat draws from its attach, one host post", async () => {
  const run = await listOut(() =>
    Promise.reject(
      Object.assign(new Error("unknown"), {
        code: "native.invalid_request",
        details: { protocol: "cmux.protocol.unknown_op" },
      }),
    ),
  );
  const client = await run.connecting;
  try {
    await settle(() => run.rows().length > 0);
    // One open asked of the host, refused; then one plain attach, not the hold.
    expect(run.hostPosts().map((post) => post.method)).toEqual(["chat.rows.open"]);
    expect(run.attaches()).toHaveLength(1);
    expect(run.attaches()[0]!.params.hold).toBeUndefined();
    const open = run.asked.findIndex((ask) => ask.method === "chat.rows.open");
    const attach = run.asked.findIndex((ask) => ask.method === "_acpmux/attach");
    expect(open).toBeLessThan(attach);
    expect(client.selectedSessionId).toBe(run.a);
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});

test("with the list still out, a host that opens: the hold's reply gives the row and the first window draws", async () => {
  let sid = "";
  const run = await listOut(async (params) => {
    sid = String(params.sid);
    return { sid };
  });
  const client = await run.connecting;
  try {
    await settle(() => run.attaches().length > 0);
    expect(run.attaches()[0]!.params).toEqual({
      sessionId: run.a,
      hold: true,
      eventStream: true,
      kinds: [...HOLD_KINDS],
      visible: expect.any(Boolean),
      attending: expect.any(Boolean),
    });
    (globalThis as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows!.receive({
      batch: 1,
      changes: recorded("window", sid),
    });
    await settle(() => run.rows().length === 11);
    expect(run.rows().map((row) => row.id)).toEqual(Array.from({ length: 11 }, (_, n) => `row-${n + 1}`));
    // The chat's row came from the hold's reply: the list never answered.
    expect(client.sessions.map((row: { sessionId: string }) => row.sessionId)).toContain(run.a);
    expect(run.hostPosts().filter((post) => post.method === "chat.rows.open")).toHaveLength(1);
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});

// A New Tab's first send (issue 44964): the switch starts a session, then opens it. The daemon refuses
// the brand-new chat's sub, so the store falls it to v1 while the open's hold is still out; the fall
// opens the chat again, as v1, and that open attaches it. The switch's open is of the same chat, so it
// resolves it: never undefined, which the switch reads as "cmux did not start a session".
test("a new chat whose sub is refused while its hold is out: the open resolves the chat", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const a = mockSessions[0]!.sessionId;
  const asked: { to: string; method: string; params: any }[] = [];
  const sids = new Map<string, string>();
  let started = "";
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  setNativeHost(async (method, params) => {
    asked.push({ to: "host", method, params });
    if (method !== "chat.rows.open") return null;
    sids.set(String(params.chat), String(params.sid));
    return { sid: params.sid };
  });
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ to: "daemon", method, params });
        if (method !== "_acpmux/attach" || params.hold !== true) return answer(method, params);
        // The new chat's hold answers only once the test lets it.
        if (params.sessionId === started) await held;
        const page = (await answer(method, { sessionId: params.sessionId })) as any;
        return { session: page.session, lastSeq: page.lastSeq, presence: {}, readThrough: null, hold: true };
      };
    }
  }
  let socket: any;
  let rows: unknown[] = [];
  const client = (await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    (snapshot) => {
      rows = snapshot.rows;
    },
    undefined,
    () => (socket = new Held()) as unknown as WebSocket,
  )) as any;
  const feed = (changes: string[]) =>
    (globalThis as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows!.receive({ batch: 1, changes });
  try {
    await settle(() => asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a));
    started = (await client.startSession("claude")) as string;
    expect(started).toBeTruthy();
    const opening: Promise<string | undefined> = client.select(started);
    await settle(() =>
      asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === started && ask.params.hold),
    );
    feed([
      JSON.stringify({ kind: "chatError", sid: sids.get(started)!, method: "sub", id: null, code: "invalid_request" }),
    ]);
    // The fall opens the chat again, as v1.
    await settle(() =>
      asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === started && !ask.params.hold),
    );
    release();
    const got = await opening;
    expect(got).toBe(started);
    expect(client.selectedSessionId).toBe(started);
    expect(await client.shownAndAttached(started)).toBe(true);
    // The fallen chat is v1's: its prompt and the agent's answer, streamed live, are drawn.
    socket.emit(started, { mux: "user_message", msg: { text: "reply with just the word pong" } });
    socket.emit(started, { mux: "turn_started" });
    socket.emit(started, { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "pong" } } });
    const drawn = () => JSON.stringify(rows);
    await settle(() => drawn().includes("pong"));
    expect(drawn()).toContain("reply with just the word pong");
  } finally {
    release();
    client.close?.();
    resetChatRowsReceiver();
  }
});

// The dogfood of issue 44964: the daemon refuses a brand-new chat's sub before the host answers its
// `chat.rows.open`, so the page has the chatError while its open is still out. That fall is the
// chat's: it opens as v1, draws its prompt and the answer streamed live, and opening it again draws
// them again. It used to be dropped, leaving the chat on a sid the store had let go: "Thinking"
// forever, and 0 rows on a reselect.
test("a new chat whose sub is refused before its open is answered: it draws as v1", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const a = mockSessions[0]!.sessionId;
  const asked: { to: string; method: string; params: any }[] = [];
  let started = "";
  const receive = (changes: string[]) =>
    (globalThis as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows!.receive({ batch: 1, changes });
  setNativeHost(async (method, params) => {
    asked.push({ to: "host", method, params });
    if (method !== "chat.rows.open") return null;
    if (params.chat === started)
      receive([
        JSON.stringify({ kind: "chatError", sid: params.sid, method: "sub", id: null, code: "invalid_request" }),
      ]);
    return { sid: params.sid };
  });
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ to: "daemon", method, params });
        if (method !== "_acpmux/attach" || params.hold !== true) return answer(method, params);
        const page = (await answer(method, { sessionId: params.sessionId })) as any;
        return { session: page.session, lastSeq: page.lastSeq, presence: {}, readThrough: null, hold: true };
      };
    }
  }
  let socket: any;
  let rows: unknown[] = [];
  const client = (await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    (snapshot) => {
      rows = snapshot.rows;
    },
    undefined,
    () => (socket = new Held()) as unknown as WebSocket,
  )) as any;
  const drawn = () => JSON.stringify(rows);
  try {
    await settle(() => asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a));
    started = (await client.startSession("claude")) as string;
    expect(await client.select(started)).toBe(started);
    await settle(() =>
      asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === started && !ask.params.hold),
    );
    socket.emit(started, { mux: "user_message", msg: { text: "reply with just the word pong" } });
    socket.emit(started, { mux: "turn_started" });
    socket.emit(started, { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "pong" } } });
    socket.emit(started, { mux: "turn_result", msg: { status: "completed" } });
    await settle(() => drawn().includes("pong"));
    expect(drawn()).toContain("reply with just the word pong");
    // Opened again, it draws from v1 again: the prompt and the answer stay.
    expect(await client.select(started)).toBe(started);
    await settle(() => drawn().includes("pong"));
    expect(drawn()).toContain("reply with just the word pong");
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});

// The switch's start (issue 44964, the create path): a selection that moves while `session/new` is
// out (a fall's open again, a list's fallback) must not drop the session the switch started, which
// left it running with no tab and the switch saying "cmux did not start a session".
test("a switch's start survives a selection that moved while session/new was out", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const [a, b] = mockSessions.map((session) => session.sessionId);
  const asked: { method: string; params: any }[] = [];
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  setNativeHost(async () => null);
  class Starting extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ method, params });
        if (method === "session/new") await held;
        return answer(method, params);
      };
    }
  }
  const client = (await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    () => {},
    undefined,
    () => new Starting() as unknown as WebSocket,
  )) as any;
  try {
    await settle(() => asked.some((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a));
    const starting: Promise<string | undefined> = client.startSession("claude");
    await settle(() => asked.some((ask) => ask.method === "session/new"));
    await client.select(b!);
    release();
    const started = await starting;
    expect(started).toBeTruthy();
    expect(asked.some((ask) => ask.method === "_acpmux/kill")).toBe(false);
  } finally {
    release();
    client.close?.();
    resetChatRowsReceiver();
  }
});
