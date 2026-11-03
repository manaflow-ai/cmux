import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../agent-session/acpmux/model";
import { ChiefWire, ExpiredSession, type ChiefIdentity, type SocketLike } from "./wire";

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
  conversationId: "conv_chief",
  userId: "user_sam",
  wireUrl: "wss://api.test/v1/wire/conv/conv_chief",
};
const head = {
  id: identity.conversationId,
  participants: [
    { id: "user_sam", kind: "human", display_name: "Sam" },
    { id: "agent_chief", kind: "agent", agent_class: "mux", display_name: "Chief" },
  ],
};
const welcome = (user = "user_sam") => ({ t: "welcome", principal: { user } });
const message = (
  seq: number,
  body: string,
  author = "agent_chief",
  clientId = `client_${seq}`,
) => ({
  id: `msg_${seq}`,
  conversation: identity.conversationId,
  seq,
  author,
  client_msg_id: clientId,
  parts: [{ type: "text", text: body }],
  created_at: "2026-11-03T12:00:00.000Z",
});
const snapshot = (seq: number, messages: ReturnType<typeof message>[] = []) => ({
  t: "snapshot",
  stream: `conv:${identity.conversationId}`,
  seq,
  state: head,
  rows: { table: "msg", rows: messages.map((row) => ({ key: row.id, n: row.seq, row })) },
});
const event = (seq: number, messages: ReturnType<typeof message>[] = []) => ({
  t: "event",
  stream: `conv:${identity.conversationId}`,
  seq,
  effects: {
    state: head,
    writes: messages.map((row) => ({ op: "upsert", table: "msg", key: row.id, n: row.seq, row })),
  },
});
const delta = (seq: number, body: string, fields: Record<string, unknown> = {}) => ({
  type: "step.delta",
  conversation: identity.conversationId,
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
  conversation: identity.conversationId,
  run: { id: "run_1", agent: "agent_chief", turn: key, status },
});

function setup(ticket?: () => Promise<string>) {
  const sockets: FakeSocket[] = [];
  const dials: { url: string; protocols: string[] }[] = [];
  const timers = new FakeTimers();
  const states: string[] = [];
  const accepted: string[] = [];
  let rows: AcpmuxRow[] = [];
  let tickets = 0;
  const client = new ChiefWire(
    {
      identity,
      timers,
      ticket: ticket ?? (async () => `secret-${++tickets}`),
      open: (url, protocols) => {
        dials.push({ url, protocols });
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket;
      },
    },
    {
      rows: (value) => {
        rows = value;
      },
      connection: (state) => states.push(state),
      accepted: (key) => accepted.push(key),
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
    await socket.frame({ type: "run.live", conversation: identity.conversationId, runs: [] });
    return socket;
  };
  return { client, sockets, dials, timers, states, accepted, last, start, ready, rows: () => rows };
}

test("the ticket stays in subprotocols; the shared cloud model renders human and Chief messages", async () => {
  const r = setup();
  const socket = await r.start();
  expect(r.dials).toEqual([
    { url: identity.wireUrl, protocols: ["cmux.wire.v1", "ticket.secret-1"] },
  ]);
  await socket.frame(welcome());
  expect(socket.sent[0]).toEqual({ t: "subscribe" });
  expect(r.states).toEqual(["connecting"]);
  await socket.frame(
    snapshot(5, [
      message(1, "Build a hello page", "user_sam"),
      message(2, "[Open it](https://preview.test)"),
    ]),
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
    conversation: identity.conversationId,
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
    conversation: identity.conversationId,
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

test("wrong-conversation frames and malformed live frames cannot change the transcript", async () => {
  const r = setup();
  const socket = await r.ready([message(1, "Kept")]);
  await socket.frame(delta(0, "Wrong", { conversation: "conv_other" }));
  await socket.frame(delta(-1, "Invalid"));
  await socket.frame({ type: "run.activity", conversation: identity.conversationId, run: "run_2" });
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
  expect(r.states.at(-1)).toBe("expired");
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

  let resolve!: (value: string) => void;
  const r = setup(
    () =>
      new Promise<string>((done) => {
        resolve = done;
      }),
  );
  r.client.connect();
  r.client.stop();
  resolve("late-ticket");
  await Promise.resolve();
  expect(r.sockets).toHaveLength(0);
  expect(r.timers.tasks.size).toBe(0);
});

test("a hung ticket attempt times out and its late answer cannot replace the retry", async () => {
  let resolve!: (value: string) => void;
  let calls = 0;
  const r = setup(() =>
    ++calls === 1
      ? new Promise<string>((done) => {
          resolve = done;
        })
      : Promise.resolve("fresh"),
  );
  r.client.connect();
  r.timers.fire(30_000);
  r.timers.fire(1_000);
  await Promise.resolve();
  expect(r.dials[0]?.protocols).toEqual(["cmux.wire.v1", "ticket.fresh"]);
  resolve("stale");
  await Promise.resolve();
  expect(r.sockets).toHaveLength(1);
  r.client.stop();
});
