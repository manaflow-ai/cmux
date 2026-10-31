// The guest's `cmux.share/1` client (agent-session/guest/shareSocket.ts) against a fake room: a
// snapshot comes first, records at or below the watermark drop, a dropped socket reconnects on a
// one-shot timer into a fresh snapshot, and `end` and `kicked` stop it for good.
import { expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import {
  backoffMs,
  type GuestEnd,
  type ShareListener,
  ShareSocket,
  type ShareSocketLike,
} from "../src/agent-session/guest/shareSocket";

class FakeSocket implements ShareSocketLike {
  sent: Record<string, unknown>[] = [];
  closed = false;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.closed = true;
  }
  /** The room sends a frame. */
  frame(t: string, fields: Record<string, unknown> = {}) {
    this.onmessage?.({ data: JSON.stringify({ v: 1, t, ...fields }) });
  }
  /** The room drops the connection. */
  drop() {
    this.onclose?.();
  }
}

const record = (seq: number): EventRecord => ({ seq, at: seq, dir: "in", kind: "agent_message_chunk", msg: {} });

function room(unresolved: string[] = []) {
  const sockets: FakeSocket[] = [];
  const timers: { run: () => void; ms: number }[] = [];
  const seen = {
    snapshots: [] as number[][],
    records: [] as number[],
    pages: [] as number[][],
    ended: [] as GuestEnd[],
    presence: [] as string[][],
  };
  const states: string[] = [];
  const listener: ShareListener = {
    snapshot: (snapshot) => seen.snapshots.push(snapshot.records.map((each) => each.seq)),
    records: (records) => seen.records.push(...records.map((each) => each.seq)),
    page: (records) => seen.pages.push(records.map((each) => each.seq)),
    presence: (participants) => seen.presence.push(participants.map((participant) => participant.id)),
    promptState: () => undefined,
    connection: (state) => states.push(state),
    ended: (reason) => seen.ended.push(reason),
  };
  const client = new ShareSocket(
    {
      url: "wss://room.test/v1/chat-shares/abc/guest",
      open: () => {
        const socket = new FakeSocket();
        sockets.push(socket);
        return socket;
      },
      setTimer: (run, ms) => timers.push({ run, ms }),
      clearTimer: () => undefined,
      unresolved: () => unresolved,
      random: () => 0,
    },
    listener,
  );
  return { client, sockets, timers, seen, states, last: () => sockets.at(-1)! };
}

test("records before the snapshot, and at or below its watermark, are dropped; copies fold once", () => {
  const r = room();
  r.client.connect();
  r.last().frame("records", { to: ["g"], records: [record(1)] });
  r.last().frame("snapshot", { chat: { title: "Chat" }, records: [record(1), record(2)], watermark: 2 });
  r.last().frame("records", { records: [record(2), record(3)] });
  r.last().frame("records", { records: [record(3), record(4)] });
  expect(r.seen.snapshots).toEqual([[1, 2]]);
  expect(r.seen.records).toEqual([3, 4]);
  expect(r.states).toEqual(["connecting", "live"]);
});

test("a page of older history comes only after the snapshot, and older() asks for it", () => {
  const r = room();
  r.client.connect();
  expect(r.client.older(10)).toBe(false);
  r.last().frame("snapshot", { records: [record(10)], watermark: 10, has_more: true });
  expect(r.client.older(10)).toBe(true);
  expect(r.last().sent).toEqual([{ v: 1, t: "older", before_seq: 10 }]);
  r.last().frame("page", { records: [record(8), record(9)], has_more: false });
  expect(r.seen.pages).toEqual([[8, 9]]);
});

test("a dropped socket reconnects on one timer and starts again from a fresh snapshot", () => {
  const r = room(["c1", "c2"]);
  r.client.connect();
  r.last().frame("snapshot", { records: [record(1)], watermark: 1, prompts: [{ client_id: "c1", state: "held" }] });
  // Prompts the snapshot does not answer are asked about.
  expect(r.last().sent).toEqual([{ v: 1, t: "prompt_status", client_ids: ["c2"] }]);
  r.last().drop();
  r.last().drop();
  expect(r.timers.length).toBe(1);
  expect(r.timers[0]!.ms).toBe(backoffMs(0, () => 0));
  r.timers[0]!.run();
  expect(r.sockets.length).toBe(2);
  // Live records from the new socket wait for its snapshot.
  r.last().frame("records", { records: [record(5)] });
  r.last().frame("snapshot", { records: [record(1), record(2), record(3)], watermark: 3 });
  r.last().frame("records", { records: [record(3), record(4)] });
  expect(r.seen.snapshots).toEqual([[1], [1, 2, 3]]);
  expect(r.seen.records).toEqual([4]);
  expect(r.states).toEqual(["connecting", "live", "reconnecting", "reconnecting", "live"]);
});

test("the backoff doubles to a ceiling and a snapshot resets it", () => {
  expect([0, 1, 2, 3].map((attempt) => backoffMs(attempt, () => 1))).toEqual([500, 1000, 2000, 4000]);
  expect(backoffMs(20, () => 1)).toBe(30_000);
  const r = room();
  r.client.connect();
  r.last().drop();
  r.timers.at(-1)!.run();
  r.last().drop();
  expect(r.timers.map((timer) => timer.ms)).toEqual([250, 500]);
  r.timers.at(-1)!.run();
  r.last().frame("snapshot", { records: [], watermark: 0 });
  r.last().drop();
  expect(r.timers.at(-1)!.ms).toBe(250);
});

for (const [frame, fields, reason] of [
  ["end", { reason: "revoked" }, "revoked"],
  ["end", { reason: "expired" }, "expired"],
  ["kicked", {}, "kicked"],
] as const)
  test(`${frame} ${reason}: the page ends and never reconnects`, () => {
    const r = room();
    r.client.connect();
    r.last().frame("snapshot", { records: [], watermark: 0 });
    r.last().frame(frame, fields);
    expect(r.seen.ended).toEqual([reason]);
    expect(r.last().closed).toBe(true);
    r.last().drop();
    r.client.connect();
    expect(r.timers).toEqual([]);
    expect(r.sockets.length).toBe(1);
    expect(r.client.send({ t: "typing", on: true })).toBe(false);
  });

test("frames of another version or malformed are ignored", () => {
  const r = room();
  r.client.connect();
  r.last().onmessage?.({ data: JSON.stringify({ v: 2, t: "snapshot", records: [record(1)] }) });
  r.last().onmessage?.({ data: "{" });
  expect(r.seen.snapshots).toEqual([]);
});

test("malformed snapshot prompts are dropped at the socket boundary", () => {
  const r = room();
  r.client.connect();
  expect(() =>
    r.last().frame("snapshot", {
      records: [],
      watermark: 0,
      prompts: [null, {}, { client_id: "guest-1", state: "held" }],
    }),
  ).not.toThrow();
  expect(r.seen.snapshots).toEqual([[]]);
});

test("malformed presence entries are dropped before reaching the page", () => {
  const r = room();
  r.client.connect();
  r.last().frame("snapshot", { records: [], watermark: 0 });
  expect(() =>
    r.last().frame("presence", {
      participants: [{}, { id: "guest-1" }, { id: "guest-2", name: "Theo" }],
    }),
  ).not.toThrow();
  expect(r.seen.presence).toEqual([["guest-2"]]);
});

test("the socket boundary drops malformed nested frame payloads and keeps rendering", () => {
  const r = room();
  r.client.connect();
  const malformed = [
    ["snapshot", { records: [null, {}], prompts: [null, {}], chat: {} }],
    [
      "records",
      {
        records: [
          {
            ...record(1),
            msg: {
              method: "session/update",
              params: { update: { sessionUpdate: "config_option_update", configOptions: [null, {}] } },
            },
          },
        ],
      },
    ],
    [
      "records",
      {
        records: [
          {
            ...record(2),
            msg: {
              method: "session/update",
              params: { update: { sessionUpdate: "agent_message_chunk", content: [null, {}] } },
            },
          },
        ],
      },
    ],
    ["page", { records: [null, {}] }],
    ["presence", { participants: [null, {}] }],
    ["prompt_state", {}],
  ] as const;
  expect(() => {
    for (const [type, fields] of malformed) r.last().frame(type, fields);
  }).not.toThrow();
  r.last().frame("snapshot", { records: [], watermark: 0, prompts: [] });
  r.last().frame("records", {
    records: [
      {
        ...record(3),
        msg: {
          method: "session/update",
          params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "still live" } } },
        },
      },
    ],
  });
  expect(r.seen.snapshots).toEqual([[], []]);
  expect(r.seen.records).toEqual([3]);
});

test("a tool call with no arguments (`rawInput: {}`) still reaches the transcript", () => {
  const r = room();
  r.client.connect();
  r.last().frame("snapshot", { records: [], watermark: 0, prompts: [] });
  r.last().frame("records", {
    records: [
      {
        ...record(1),
        kind: "tool_call",
        msg: {
          method: "session/update",
          params: {
            update: { sessionUpdate: "tool_call", toolCallId: "t-1", title: "List files", kind: "read", rawInput: {} },
          },
        },
      },
    ],
  });
  expect(r.seen.records).toEqual([1]);
});
