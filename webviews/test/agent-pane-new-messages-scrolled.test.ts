// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// "N new messages" placed by a scroll up (direct.ts `placeScrolledSince`; Leo, 2026-11-15: "we needto
// properly do somthing like this in the gui somehow"). Scrolled up while the chat keeps going, the line
// goes after the last record the view followed, once something new to read (sinceNews.ts) comes after it; and a chat that already
// draws a line (a return's, with its recap) keeps it where it is, read or not, so no row is taken out
// above the reader.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { SINCE_DIVIDER, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000044a1";
const START = Date.UTC(2026, 10, 15, 22, 0, 0);

type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const reply = (seq: number, text: string): Event => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const mux = (seq: number, kind: string, msg: Record<string, unknown> = {}): Event => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind,
  msg,
});
/// A finished turn from `seq`: the prompt, its start, a reply, its end (four records).
const turn = (seq: number, n: number): Event[] => [
  mux(seq, "user_message", { text: `Step ${n}` }),
  mux(seq + 1, "turn_started"),
  reply(seq + 2, `Reply ${n}.`),
  mux(seq + 3, "turn_result", { status: "completed" }),
];

function fakeDaemon(history: Event[], listed: Record<string, unknown>) {
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness: "claude", status: "idle", ...listed };
  let socket: any;
  const answer = (method: string) => {
    const lastSeq = history.at(-1)?.seq ?? 0;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: Event[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  const settled = async (ok: () => boolean) => {
    const deadline = performance.now() + 2_000;
    while (!ok()) {
      if (performance.now() > deadline) throw new Error("timed out waiting for the chat");
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  };
  return {
    client,
    settled,
    rows: () => (snapshot?.rows ?? []) as AcpmuxRow[],
    sinceKey: () => snapshot?.sinceKey as string | undefined,
  };
}

/// The text of the row right after the line, and the line's mark.
const afterLine = (rows: readonly AcpmuxRow[]) => {
  const at = rows.findIndex((row) => row.id === SINCE_DIVIDER);
  return at < 0 ? undefined : rows.slice(at + 1).find((row) => row.kind === "user" || row.kind === "assistant");
};

test("scrolled up while the chat goes on, the line goes after what the view last followed", async () => {
  const daemon = fakeDaemon([...turn(1, 1), ...turn(5, 2)], {});
  const chat = await connect(daemon);
  try {
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 2."));
    expect(chat.sinceKey()).toBeUndefined();
    chat.client.setFollowing(false);
    // The person's own prompt and a turn that only starts are not news (sinceNews.ts): no line yet.
    daemon.push([mux(9, "user_message", { text: "Step 3" }), mux(10, "turn_started")]);
    await chat.settled(() => chat.rows().some((row) => row.text === "Step 3"));
    expect(chat.sinceKey()).toBeUndefined();
    // A reply while the turn still runs is not new either (Leo, 2026-11-25: "dont mark it as new if
    // it's still going"): no line yet.
    daemon.push([reply(11, "Reply 3.")]);
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 3."));
    expect(chat.sinceKey()).toBeUndefined();
    // The turn ends with the reader still scrolled away: what they did not see is new, and the line
    // goes after what the view last followed, before the prompt.
    daemon.push([mux(12, "turn_result", { status: "completed" })]);
    await chat.settled(() => chat.sinceKey() !== undefined);
    expect(chat.sinceKey()).toBe(`${CHAT}:8`);
    expect(afterLine(chat.rows())?.text).toBe("Step 3");
    // Back at the latest and away again: the one line stays where it was.
    chat.client.setFollowing(true);
    chat.client.setFollowing(false);
    daemon.push(turn(13, 4));
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 4."));
    expect(chat.sinceKey()).toBe(`${CHAT}:8`);
  } finally {
    chat.client.close();
  }
});

test("a turn that ends while the reader follows the latest row places no line", async () => {
  const daemon = fakeDaemon([...turn(1, 1)], {});
  const chat = await connect(daemon);
  try {
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 1."));
    // Scrolled up mid-turn while it streams, then back at the bottom before it ends.
    daemon.push([mux(5, "user_message", { text: "Step 2" }), mux(6, "turn_started")]);
    chat.client.setFollowing(false);
    daemon.push([reply(7, "Reply 2.")]);
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 2."));
    expect(chat.sinceKey()).toBeUndefined();
    chat.client.setFollowing(true);
    daemon.push([mux(8, "turn_result", { status: "completed" })]);
    daemon.push(turn(9, 3));
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 3."));
    expect(chat.sinceKey()).toBeUndefined();
  } finally {
    chat.client.close();
  }
});

test("a return's line keeps its place, read or not, when the reader scrolls up after it", async () => {
  // The person had seen through seq 4; turn 2 ended while they were away.
  const daemon = fakeDaemon([...turn(1, 1), ...turn(5, 2)], { unreadTurns: 1, seenSeq: 4, unread: true });
  const chat = await connect(daemon);
  try {
    await chat.settled(() => chat.sinceKey() !== undefined);
    const mark = chat.sinceKey();
    expect(afterLine(chat.rows())?.text).toBe("Step 2");
    // Landing at the line is a scroll away from the latest; the chat keeps working.
    chat.client.setFollowing(false);
    daemon.push(turn(9, 3));
    await chat.settled(() => chat.rows().some((row) => row.text === "Reply 3."));
    expect(chat.sinceKey()).toBe(mark);
    expect(afterLine(chat.rows())?.text).toBe("Step 2");
    expect(chat.rows().filter((row) => row.id === SINCE_DIVIDER)).toHaveLength(1);
  } finally {
    chat.client.close();
  }
});
