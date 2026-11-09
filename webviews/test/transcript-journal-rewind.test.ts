// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A Cloud chat's journal that went backwards: the agent's new output replaces the rows the pane
// drew of the records the machine lost, instead of being refused as already seen.
// Leo, 2026-11-09: "keep on working on the stuff, especially cloud stuff, and getting that
// reliable and ergonomic. Like, the ergonomic part is super big for us."
//
// acpmux shows a record before it is synced to disk (up to about a second, store/durability.rs).
// A Cloud machine that hard-stops (power loss, a hypervisor kill, a disk restored on resume)
// comes back on a log that ends before records the pane drew, and its new records reuse those
// seqs. The pane held them as seen: each new record up to its old cursor was dropped, an attach
// kept the stale rows over the page's, and a read from its cursor was refused (`cursor_future`).
//   - The Mac's acpmux says so (`_acpmux/rewound`, from its peer link's replay): the pane drops
//     its rows past the journal's new end and reads on from there.
//   - A read refused with `cursor_future` says so too: the same, from the end it names, which may
//     be past where the journal went back to (the agent wrote on), so the newest records kept are
//     read again as the machine has them.
//   - A reconnect's attach whose log ends before the rows held: the same, older rows kept.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000f2";
const START = Date.UTC(2026, 10, 9, 10, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };

const chunk = (seq: number, text: string): Rec => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 100,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", messageId: "m-1", content: { type: "text", text } } },
  },
});
const mux = (seq: number, kind: string, msg: Record<string, unknown>): Rec => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 100,
  dir: "mux",
  kind,
  msg,
});

const opened = [
  mux(1, "user_message", { text: "summarize the build", promptId: "p-1", turnId: "turn-1" }),
  mux(2, "turn_started", { promptId: "p-1", turnId: "turn-1" }),
];
/// What the machine synced before it stopped.
const synced = [...opened, chunk(3, "Synced one. "), chunk(4, "Synced two. ")];
/// What the pane drew that the machine never synced.
const lost = [chunk(5, "LOST one. "), chunk(6, "LOST two. ")];
/// What the agent wrote after the machine came back: the same seqs, other words.
const fresh = [chunk(5, "Fresh one. "), chunk(6, "Fresh two. ")].map((record) => ({
  ...record,
  at: record.at + 60_000,
}));

/// A pane attached to a chat whose machine's journal is `host.log`; `_acpmux/events` reads it as
/// acpmux does, refusing a cursor past its end (`cursor_future`).
async function pane(log: Rec[]) {
  const host = { log };
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: false,
    turnCount: 1,
    updatedAt: START,
    createdAt: 100,
  };
  const reads: number[] = [];
  const last = () => host.log.at(-1)?.seq ?? 0;
  const answer = (method: string, params: any): { result?: unknown; error?: unknown } => {
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions: [session] } };
      case "_acpmux/attach":
        return { result: { session, lastSeq: last(), pageThrough: last(), events: host.log, hasMore: false } };
      case "_acpmux/events": {
        const after = Number(params?.afterSeq ?? 0);
        const before = typeof params?.beforeSeq === "number" ? params.beforeSeq : undefined;
        if (before === undefined) reads.push(after);
        if (after > last())
          return {
            error: { code: -32602, message: `cursor_future: afterSeq ${after} is beyond the last event ${last()}` },
          };
        let page = host.log.filter((r) => r.seq > after && (before === undefined || r.seq < before));
        if (before !== undefined) page = page.slice(-Number(params?.limit ?? 5000));
        return { result: { events: page, hasMore: false, lastSeq: last(), createdAt: 100 } };
      }
      default:
        return { result: null };
    }
  };
  let socket: any;
  const open = () => {
    const mine: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          mine.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, message.params) }) }),
        );
      },
      close() {
        mine.readyState = 3;
      },
    };
    socket = mine;
    queueMicrotask(() => mine.onopen?.());
    return mine as WebSocket;
  };
  let rows: AcpmuxRow[] = [];
  let waiters: { holds: () => boolean; done: () => void }[] = [];
  const check = () => {
    const due = waiters.filter((waiter) => waiter.holds());
    waiters = waiters.filter((waiter) => !due.includes(waiter));
    for (const waiter of due) waiter.done();
  };
  /// Resolves once the pane's rows show `holds`; bun's test timeout is its deadline.
  const until = (holds: () => boolean) =>
    new Promise<void>((done) => {
      waiters.push({ holds, done });
      check();
    });
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => {
      rows = snapshot.rows;
      check();
    },
    undefined,
    open,
  );
  await until(() => rows.length > 0);
  const notify = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  const settle = () => new Promise((done) => setTimeout(done, 20));
  return {
    host,
    reads,
    live: (record: Rec) => notify("_acpmux/event", record),
    notify,
    reply: () =>
      rows
        .filter((row) => row.kind === "assistant")
        .map((row) => row.text)
        .join(""),
    /// The socket drops and the pane connects again (its reconnect, without waiting out the delay).
    reconnect: () => (client as unknown as { open: () => Promise<void> }).open(),
    settle,
    until,
  };
}

test("the Mac's acpmux saying the machine's journal went back replaces the rows it lost", async () => {
  const chat = await pane([...synced, ...lost]);
  await chat.until(() => chat.reply().includes("LOST two."));
  // The machine hard-stopped: it is back on what it synced, and its link's replay says so first.
  chat.host.log = [...synced];
  chat.notify("_acpmux/rewound", { sessionId: CHAT, lastSeq: 4, peer: "cloud" });
  for (const record of synced) chat.live(record);
  await chat.until(() => !chat.reply().includes("LOST"));
  // The agent writes on under the seqs the lost records had.
  chat.host.log = [...synced, ...fresh];
  for (const record of fresh) chat.live(record);
  await chat.until(() => chat.reply().includes("Fresh two."));
  expect(chat.reply()).toBe("Synced one. Synced two. Fresh one. Fresh two. ");
  // It read on from the journal's new end, after reading back what it kept.
  await chat.settle();
  expect(chat.reads).toEqual([4]);
});

test("a notice of another chat or a journal that did not go back changes nothing", async () => {
  const chat = await pane([...synced, ...lost]);
  await chat.until(() => chat.reply().includes("LOST two."));
  chat.notify("_acpmux/rewound", { sessionId: "another-chat", lastSeq: 4 });
  chat.notify("_acpmux/rewound", { sessionId: CHAT, lastSeq: 6 });
  await chat.settle();
  expect(chat.reply()).toBe("Synced one. Synced two. LOST one. LOST two. ");
  expect(chat.reads).toEqual([]);
});

test("a read refused as past the journal's end drops the rows past it and reads from there", async () => {
  const chat = await pane([...synced, ...lost]);
  await chat.until(() => chat.reply().includes("LOST two."));
  // No notice reached this pane (a remote wire to the machine itself): its new records come
  // live under the old seqs, and a lag has the pane read from its cursor, which is past the end.
  chat.host.log = [...synced, fresh[0]!];
  chat.live(fresh[0]!);
  chat.notify("_acpmux/lagged", { dropped: 1, reason: "output_queue_full" });
  await chat.until(() => chat.reply().includes("Fresh one."));
  expect(chat.reply()).toBe("Synced one. Synced two. Fresh one. ");
  expect(chat.reads).toEqual([6, 5]);
  chat.host.log = [...synced, ...fresh];
  chat.live(fresh[1]!);
  await chat.until(() => chat.reply().includes("Fresh two."));
  expect(chat.reply()).toBe("Synced one. Synced two. Fresh one. Fresh two. ");
});

test("a reconnect's attach to a journal that went back replaces the rows it lost", async () => {
  const chat = await pane([...synced, ...lost]);
  await chat.until(() => chat.reply().includes("LOST two."));
  // The pane connects again to the machine, back on what it synced and already writing on.
  chat.host.log = [...synced, fresh[0]!];
  await chat.reconnect();
  await chat.until(() => chat.reply().includes("Fresh one."));
  expect(chat.reply()).toBe("Synced one. Synced two. Fresh one. ");
  chat.host.log = [...synced, ...fresh];
  chat.live(fresh[1]!);
  await chat.until(() => chat.reply().includes("Fresh two."));
  expect(chat.reply()).toBe("Synced one. Synced two. Fresh one. Fresh two. ");
});
