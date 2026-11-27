import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../agent-session/acpmux/model";
import { ChiefWire, ExpiredSession, type ChiefIdentity, type ChiefTicket, type SocketLike } from "./wire";

class FakeSocket implements SocketLike {
  sent: Record<string, unknown>[] = [];
  closed = false;
  onopen: (() => void) | null = null;
  onmessage: SocketLike["onmessage"] = null;
  onclose: SocketLike["onclose"] = null;
  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.closed = true;
  }
  async frame(frame: Record<string, unknown>) {
    await this.onmessage?.({ data: JSON.stringify(frame) });
  }
  drop(code = 1006) {
    this.onclose?.({ code });
  }
}

class FakeTimers {
  tasks = new Map<number, { run: () => void; ms: number }>();
  private next = 0;
  set = (run: () => void, ms: number) => {
    const id = ++this.next;
    this.tasks.set(id, { run, ms });
    return id;
  };
  clear = (id: unknown) => {
    this.tasks.delete(id as number);
  };
  fire(ms: number) {
    const entry = [...this.tasks].find(([, task]) => task.ms === ms);
    expect(entry).toBeDefined();
    this.tasks.delete(entry![0]);
    entry![1].run();
  }
}

const identity: ChiefIdentity = {
  handle: "sam",
  mainConversationId: "conv_chief",
  chiefId: "chief_sam",
};
const head = {
  id: identity.mainConversationId,
  participants: [
    { id: "user_sam", kind: "human", display_name: "Sam" },
    { id: "agent_chief", kind: "agent", agent_class: "mux", display_name: "Chief" },
  ],
};
const welcome = (user = "user_sam") => ({ t: "welcome", principal: { user } });
const message = (seq: number, body: string, author = "agent_chief", clientId = `client_${seq}`) => ({
  id: `msg_${seq}`,
  conversation: identity.mainConversationId,
  seq,
  author,
  client_msg_id: clientId,
  parts: [{ type: "text", text: body }],
  created_at: "2026-11-03T12:00:00.000Z",
});
const snapshot = (seq: number, messages: ReturnType<typeof message>[] = []) => ({
  t: "snapshot",
  stream: `conv:${identity.mainConversationId}`,
  seq,
  state: head,
  rows: { table: "msg", rows: messages.map((row) => ({ key: row.id, n: row.seq, row })) },
});
const event = (seq: number, messages: ReturnType<typeof message>[] = []) => ({
  t: "event",
  stream: `conv:${identity.mainConversationId}`,
  seq,
  effects: {
    state: head,
    writes: messages.map((row) => ({ op: "upsert", table: "msg", key: row.id, n: row.seq, row })),
  },
});
const delta = (seq: number, body: string, fields: Record<string, unknown> = {}) => ({
  type: "step.delta",
  conversation: identity.mainConversationId,
  author: "agent_chief",
  run: "run_1",
  step: "talk:0",
  kind: "talk",
  seq,
  text: body,
  ...fields,
});
const turn = (status: string, key = "reply-key") => ({
  t: "conversation-run-changed",
  conversation: identity.mainConversationId,
  run: { id: "run_1", author: "agent_chief", turn: key, status },
});

const ticketFor = (ticket: string): ChiefTicket => ({
  ticket,
  websocketUrl: `wss://api.test/chief-wire/${ticket}`,
});

function setup(ticket?: () => Promise<ChiefTicket>) {
  const sockets: FakeSocket[] = [];
  const dials: { url: string; protocols: string[] }[] = [];
  const timers = new FakeTimers();
  const states: string[] = [];
  const accepted: string[] = [];
  const logins: string[] = [];
  let committed: AcpmuxRow[] = [];
  let live: AcpmuxRow[] = [];
  const publications: { committed: AcpmuxRow[]; live: AcpmuxRow[] }[] = [];
  let tickets = 0;
  const client = new ChiefWire(
    {
      identity,
      timers,
      ticket: ticket ?? (async () => ticketFor(`secret-${++tickets}`)),
      open: (url, protocols) => {
        dials.push({ url, protocols });
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket;
      },
    },
    {
      rows: (history, tail) => {
        committed = history;
        live = tail;
        publications.push({ committed: history, live: tail });
      },
      connection: (state) => states.push(state),
      accepted: (key) => accepted.push(key),
      machineLogin: (run) => logins.push(run),
    },
  );
  const last = () => sockets.at(-1)!;
  const start = async () => {
    client.connect();
    await Promise.resolve();
    return last();
  };
  const ready = async (messages: ReturnType<typeof message>[] = []) => {
    const socket = await start();
    await socket.frame(welcome());
    await socket.frame(snapshot(5, messages));
    await socket.frame({ type: "run.live", conversation: identity.mainConversationId, runs: [] });
    return socket;
  };
  return {
    client,
    sockets,
    dials,
    timers,
    states,
    accepted,
    logins,
    last,
    start,
    ready,
    publications,
    rows: () => [...committed, ...live],
    committed: () => committed,
    live: () => live,
  };
}

test("the ticket stays in subprotocols; the shared cloud model renders human and Chief messages", async () => {
  const r = setup();
  const socket = await r.start();
  expect(r.dials).toEqual([
    { url: ticketFor("secret-1").websocketUrl, protocols: ["cmux.wire.v1", "ticket.secret-1"] },
  ]);
  await socket.frame(welcome());
  expect(socket.sent[0]).toEqual({ t: "subscribe" });
  expect(r.states).toEqual(["connecting"]);
  await socket.frame(
    snapshot(5, [message(1, "Build a hello page", "user_sam"), message(2, "[Open it](https://preview.test)")]),
  );
  expect(r.rows().map((row) => [row.kind, row.text])).toEqual([
    ["user", "Build a hello page"],
    ["assistant", "[Open it](https://preview.test)"],
  ]);
  expect(r.accepted).toEqual(["client_1"]);
  expect(r.states.at(-1)).toBe("live");
  r.client.stop();
});

test("stream positions drop repeats, request one snapshot for a gap, and resume a caught-up socket", async () => {
  const r = setup();
  const first = await r.ready([message(1, "Old"), message(2, "Original")]);
  await first.frame(event(6, [message(2, "Edited")]));
  await first.frame(event(6, [message(2, "Repeated")]));
  await first.frame(event(8, [message(3, "Gap")]));
  await first.frame(event(7, [message(3, "Ignored while resyncing")]));
  expect(r.rows().map((row) => row.text)).toEqual(["Old", "Edited"]);
  expect(first.sent.filter((frame) => frame.t === "snapshot.request")).toEqual([
    { t: "snapshot.request", pending: [] },
  ]);
  await first.frame(snapshot(8, [message(2, "Edited"), message(3, "Recovered")]));
  expect(r.rows().map((row) => row.text)).toEqual(["Old", "Edited", "Recovered"]);
  first.drop();
  first.drop();
  expect([...r.timers.tasks.values()].map((task) => task.ms)).toEqual([1_000]);
  r.timers.fire(1_000);
  await Promise.resolve();
  await r.last().frame(welcome());
  expect(r.last().sent[0]).toEqual({ t: "subscribe", after_seq: 8 });
  expect(r.states.at(-1)).toBe("live");
  expect(r.dials[1]!.url).toBe(ticketFor("secret-2").websocketUrl);
  expect(r.dials[1]!.protocols).toEqual(["cmux.wire.v1", "ticket.secret-2"]);
  r.client.stop();
  expect(r.timers.tasks.size).toBe(0);
});

test("a changed principal stops before the previous account's outbox can send", async () => {
  const r = setup();
  const socket = await r.ready([message(1, "Previous account")]);
  socket.drop();
  r.timers.fire(1_000);
  await Promise.resolve();
  await r.last().frame(welcome("user_other"));
  expect(r.last().sent).toEqual([]);
  expect(r.rows()).toEqual([]);
  expect(r.states.at(-1)).toBe("expired");
  r.client.stop();
});

test("delete, retract and edit change existing rows without inventing new messages", async () => {
  const r = setup();
  const socket = await r.ready([message(1, "One"), message(2, "Two"), message(3, "Three")]);
  const next = event(6, [
    { ...message(2, "Two"), retracted_at: "2026-11-03T12:00:01Z" } as ReturnType<typeof message>,
    message(3, "Edited"),
  ]);
  next.effects.writes.push({
    op: "delete",
    table: "msg",
    key: "msg_1",
  } as (typeof next.effects.writes)[number]);
  await socket.frame(next);
  expect(r.rows().map((row) => [row.id, row.text])).toEqual([["msg_3", "Edited"]]);
  r.client.stop();
});

test("streaming uses per-step ordering and holds its completed reply until the committed nonce arrives", async () => {
  const r = setup();
  const socket = await r.ready([message(1, "Prompt", "user_sam")]);
  const committed = r.rows()[0];
  await socket.frame(turn("running"));
  await socket.frame(delta(0, "Hello"));
  await socket.frame(delta(1, " world"));
  await socket.frame(delta(1, " duplicate"));
  expect(r.rows().at(-1)?.text).toBe("Hello world");
  expect(r.rows()[0]).toBe(committed);
  await socket.frame(delta(3, " missed"));
  expect(socket.sent.filter((frame) => frame.t === "run.live.get")).toHaveLength(2);
  await socket.frame({
    type: "run.live",
    conversation: identity.mainConversationId,
    runs: [
      {
        author: "agent_chief",
        run: "run_1",
        steps: [{ step: "talk:0", kind: "talk", seq: 3, text: "Hello world!" }],
      },
    ],
  });
  await socket.frame(delta(4, "", { final: true }));
  await socket.frame({
    type: "run.live",
    conversation: identity.mainConversationId,
    runs: [{ author: "agent_chief", run: "run_1", steps: [] }],
  });
  expect(r.rows().at(-1)?.text).toBe("Hello world!");
  await socket.frame(turn("done"));
  expect(r.rows().at(-1)?.text).toBe("Hello world!");
  await socket.frame(event(6, [message(2, "Hello world!", "agent_chief", "reply-key")]));
  expect(r.rows().map((row) => row.text)).toEqual(["Prompt", "Hello world!"]);
  expect(r.rows().some((row) => row.id.startsWith("chief-live:"))).toBe(false);
  await socket.frame(delta(5, " late"));
  expect(r.rows().map((row) => row.text)).toEqual(["Prompt", "Hello world!"]);
  r.client.stop();
});

test("a posted reply arriving before its run record also settles the live text", async () => {
  const r = setup();
  const socket = await r.ready();
  await socket.frame(delta(0, "Answer"));
  await socket.frame(event(6, [message(1, "Answer", "agent_chief", "reply-key")]));
  await socket.frame(turn("done"));
  expect(r.rows().map((row) => row.text)).toEqual(["Answer"]);
  r.client.stop();
});

test("authoritative completed talk rows replace a partial delta and survive an empty live snapshot", async () => {
  const r = setup();
  const socket = await r.ready();
  await socket.frame(turn("running"));
  await socket.frame(delta(0, "Incomplete draft"));
  await socket.frame({
    ...turn("done"),
    steps: [
      { id: "talk:0", kind: "talk", seq: 2, rev: 8, status: "done", text: "The complete answer." },
      { id: "thought", kind: "thought", seq: 1, text: "Private reasoning" },
    ],
  });
  expect(r.live().map((row) => [row.text, row.streaming])).toEqual([["The complete answer.", false]]);
  await socket.frame({ type: "run.live", conversation: identity.mainConversationId, runs: [] });
  expect(r.live().map((row) => row.text)).toEqual(["The complete answer."]);

  // The same author's next message is not this run's receipt.
  await socket.frame(event(6, [message(1, "Other reply", "agent_chief", "different-turn")]));
  expect(r.live()).toHaveLength(1);
  await socket.frame(event(7, [message(2, "The complete answer.", "agent_chief", "reply-key")]));
  expect(r.live()).toEqual([]);
  expect(r.committed().map((row) => row.text)).toEqual(["Other reply", "The complete answer."]);
  await socket.frame({
    ...turn("done"),
    steps: [{ id: "talk:0", kind: "talk", text: "Late row" }],
  });
  expect(r.live()).toEqual([]);
  r.client.stop();
});

test("a mid-run join uses authoritative step placement and resyncs before appending numbered deltas", async () => {
  const r = setup();
  const socket = await r.ready();
  await socket.frame({
    ...turn("running"),
    steps: [
      { id: "later-segment", kind: "talk", seq: 12, rev: 2, text: "Second segment" },
      { id: "first-segment", kind: "talk", seq: 4, rev: 7, text: "First segment" },
      { id: "cut-segment", kind: "talk", seq: 6, truncated: true, text: "Not a complete row" },
    ],
  });
  expect(r.live().at(-1)?.text).toBe("First segment\n\nSecond segment");
  await socket.frame({
    type: "run.live",
    conversation: identity.mainConversationId,
    runs: [{ author: "agent_chief", run: "run_1", steps: [] }],
  });
  expect(r.live().at(-1)?.text).toBe("First segment\n\nSecond segment");
  await socket.frame(delta(1, " unsafe append", { step: "later-segment" }));
  expect(r.live().at(-1)?.text).toBe("First segment\n\nSecond segment");
  expect(socket.sent.filter((frame) => frame.t === "run.live.get")).toHaveLength(2);
  await socket.frame({
    type: "run.live",
    conversation: identity.mainConversationId,
    runs: [
      {
        author: "agent_chief",
        run: "run_1",
        steps: [{ step: "later-segment", kind: "talk", seq: 3, text: "Second segment caught up" }],
      },
    ],
  });
  await socket.frame(delta(4, "!", { step: "later-segment" }));
  expect(r.live().at(-1)?.text).toBe("First segment\n\nSecond segment caught up!");
  r.client.stop();
});

test("a final talk delta stays visible when run.live no longer lists its run before the done record", async () => {
  const r = setup();
  const socket = await r.ready();
  await socket.frame(turn("running"));
  await socket.frame(delta(0, "Final text", { final: true }));
  await socket.frame({ type: "run.live", conversation: identity.mainConversationId, runs: [] });
  expect(r.live().map((row) => [row.text, row.streaming])).toEqual([["Final text", false]]);
  await socket.frame(turn("done"));
  await socket.frame(event(6, [message(1, "Final text", "agent_chief", "reply-key")]));
  expect(r.live()).toEqual([]);
  expect(r.committed().map((row) => row.text)).toEqual(["Final text"]);
  r.client.stop();
});

test("concurrent completed replies hand off only to their matching author and turn", async () => {
  const r = setup();
  const socket = await r.ready();
  for (const [id, author, turnId, text] of [
    ["run_1", "agent_chief", "turn_one", "One"],
    ["run_2", "agent_chief", "turn_two", "Two"],
  ])
    await socket.frame({
      type: "conversation-run-changed",
      conversation: identity.mainConversationId,
      run: { id, author, turn: turnId, status: "done" },
      steps: [{ id: "answer", kind: "talk", status: "done", seq: 0, text }],
    });
  await socket.frame(event(6, [message(1, "Wrong author", "agent_other", "turn_one")]));
  expect(r.live().map((row) => row.text)).toEqual(["One", "Two"]);
  await socket.frame(event(7, [message(2, "One", "agent_chief", "turn_one")]));
  expect(r.live().map((row) => row.text)).toEqual(["Two"]);
  await socket.frame(event(8, [message(3, "Two", "agent_chief", "turn_two")]));
  expect(r.live()).toEqual([]);
  r.client.stop();
});

test("streamed tokens publish a separate live tail without iterating or replacing committed history", async () => {
  const r = setup();
  const socket = await r.ready(Array.from({ length: 2_000 }, (_, index) => message(index + 1, `Earlier ${index}`)));
  const history = r.committed();
  const start = r.publications.length;
  const iterate = history[Symbol.iterator];
  let reads = 0;
  Object.defineProperty(history, Symbol.iterator, {
    configurable: true,
    value: function* (this: AcpmuxRow[]) {
      reads++;
      yield* iterate.call(this);
    },
  });
  for (let seq = 0; seq < 30; seq++) await socket.frame(delta(seq, "x"));
  expect(r.live().at(-1)?.text).toBe("x".repeat(30));
  expect(r.publications.slice(start).every((value) => value.committed === history)).toBe(true);
  expect(reads).toBe(0);
  expect(r.committed()).toBe(history);
  expect(r.committed()).toHaveLength(2_000);
  expect(r.live()).toHaveLength(1);
  r.client.stop();
});

test("wrong-conversation frames and malformed live frames cannot change the transcript", async () => {
  const r = setup();
  const socket = await r.ready([message(1, "Kept")]);
  await socket.frame(delta(0, "Wrong", { conversation: "conv_other" }));
  await socket.frame(delta(-1, "Invalid"));
  await socket.frame({
    type: "run.activity",
    conversation: identity.mainConversationId,
    run: "run_2",
  });
  await socket.frame({ ...snapshot(20, [message(2, "Wrong")]), stream: "conv:other" });
  expect(r.rows().map((row) => row.text)).toEqual(["Kept"]);
  r.client.stop();
});

test("asynchronous Blob frames retain arrival order and an old socket's late decode is ignored", async () => {
  const r = setup();
  const socket = await r.ready();
  let release!: (value: string) => void;
  const pending = new Promise<string>((resolve) => {
    release = resolve;
  });
  const blob = new Blob();
  blob.text = () => pending;
  const delayed = socket.onmessage!({ data: blob });
  const later = socket.frame(event(7, [message(2, "Second")]));
  release(JSON.stringify(event(6, [message(1, "First")])));
  await delayed;
  await later;
  expect(r.rows().map((row) => row.text)).toEqual(["First", "Second"]);

  const oldHandler = socket.onmessage!;
  let finish!: (value: string) => void;
  const old = new Blob();
  old.text = () =>
    new Promise<string>((resolve) => {
      finish = resolve;
    });
  const stale = oldHandler({ data: old });
  await Promise.resolve();
  socket.drop();
  r.timers.fire(1_000);
  await Promise.resolve();
  await r.last().frame(welcome());
  finish(JSON.stringify(event(8, [message(3, "Stale")])));
  await stale;
  expect(r.rows().map((row) => row.text)).toEqual(["First", "Second"]);
  r.client.stop();
});

test.each([4401, 4403])("authentication close %s stops reconnecting", async (code) => {
  const r = setup();
  const socket = await r.ready();
  socket.drop(code);
  expect(r.states.at(-1)).toBe(code === 4401 ? "expired" : "inaccessible");
  expect(r.timers.tasks.size).toBe(0);
  r.client.stop();
});

test("an expired ticket terminates, and disposal ignores a ticket still in flight", async () => {
  const expired = setup(async () => {
    throw new ExpiredSession();
  });
  await expired.start();
  expect(expired.states.at(-1)).toBe("expired");
  expect(expired.timers.tasks.size).toBe(0);
  expired.client.stop();

  let resolve!: (value: ChiefTicket) => void;
  const r = setup(
    () =>
      new Promise<ChiefTicket>((done) => {
        resolve = done;
      }),
  );
  r.client.connect();
  r.client.stop();
  resolve(ticketFor("late-ticket"));
  await Promise.resolve();
  expect(r.sockets).toHaveLength(0);
  expect(r.timers.tasks.size).toBe(0);
});

test("a hung ticket attempt times out and its late answer cannot replace the retry", async () => {
  let resolve!: (value: ChiefTicket) => void;
  let calls = 0;
  const r = setup(() =>
    ++calls === 1
      ? new Promise<ChiefTicket>((done) => {
          resolve = done;
        })
      : Promise.resolve(ticketFor("fresh")),
  );
  r.client.connect();
  r.timers.fire(30_000);
  r.timers.fire(1_000);
  await Promise.resolve();
  expect(r.dials[0]?.protocols).toEqual(["cmux.wire.v1", "ticket.fresh"]);
  resolve(ticketFor("stale"));
  await Promise.resolve();
  expect(r.sockets).toHaveLength(1);
  r.client.stop();
});

test("machine sign-in requires the exact Chief, conversation, step id and valid root run", async () => {
  const fixture = setup();
  const socket = await fixture.ready();
  const frame = {
    t: "conversation-run-changed",
    conversation: identity.mainConversationId,
    run: { id: "run_42", author: identity.chiefId, status: "running" },
    steps: [{ id: "machine:sign-in", kind: "note", text: "Localized waiting text" }],
  };
  await socket.frame({ ...frame, conversation: "conv_other" });
  await socket.frame({ ...frame, run: { ...frame.run, author: "agent_impostor" } });
  await socket.frame({
    ...frame,
    steps: [{ id: "other", kind: "note", text: "Waiting for claude sign-in" }],
  });
  await socket.frame({ ...frame, run: { ...frame.run, id: "run_42/subrun" } });
  expect(fixture.logins).toEqual([]);
  await socket.frame(frame);
  await socket.frame(frame);
  expect(fixture.logins).toEqual(["run_42"]);
  fixture.client.stop();
});

test("persisted owner auth nonce recovers sign-in after reload without accepting user prose or old runs", async () => {
  const fixture = setup();
  const socket = await fixture.ready([
    message(1, "Sign in to Claude to continue.", "user_sam", `chief-machine-auth:${identity.chiefId}:run_40`),
    message(2, "Localized sign-in message", identity.chiefId, `chief-machine-auth:${identity.chiefId}:run_42`),
    message(3, "Unrelated author", "agent_other", `chief-machine-auth:${identity.chiefId}:run_43`),
    message(4, "Wrong nonce owner", identity.chiefId, "chief-machine-auth:agent_other:run_44"),
  ]);
  expect(fixture.logins).toEqual(["run_42"]);
  await socket.frame(
    event(6, [message(5, "Earlier run replay", identity.chiefId, `chief-machine-auth:${identity.chiefId}:run_41`)]),
  );
  expect(fixture.logins).toEqual(["run_42"]);
  fixture.client.stop();
});
