// l10n-allow-file: test fixture recap text, not shipped UI.
// A session recap's × (RecapNote): the client drops the recap's row, so no empty row slot stays
// in the transcript, and the recap stays dismissed on this device when the chat attaches again.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

// The page's localStorage, which bun has none of.
const realStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
beforeEach(() => {
  const items = new Map<string, string>();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    },
  });
});
afterEach(() => {
  if (realStorage) Object.defineProperty(globalThis, "localStorage", realStorage);
  else delete (globalThis as { localStorage?: unknown }).localStorage;
});

const CHAT = "0190a000-0000-7000-8000-0000000000e9";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// A daemon over a fake socket for a chat on `harness`: attach answers with `history`; `push`
/// sends live events.
function fakeDaemon(history: Recorded[], harness: string, family: string) {
  let socket: any;
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness, family, status: "idle" };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: lastSeq(), events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: lastSeq() };
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
  const push = (events: Recorded[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  let attached = false;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
      attached ||= next.connection === "connected";
    },
    undefined,
    daemon.open,
  );
  await until(() => attached, "the attach");
  const recaps = () =>
    (snapshot.rows as AcpmuxRow[]).filter((row) => row.kind === "recap").map((row) => row.recap?.text);
  return { client, recaps };
}

const RECAP = "You were fixing the flaky login test; the retry fix is in and CI is running.";

test("dismissing a recap drops its row, and it stays dismissed when the chat attaches again", async () => {
  const history = () =>
    record([
      ["mux", "user_message", { text: "fix the login test" }],
      ["mux", "recap", { text: RECAP, awayMs: 360_000 }],
    ]);
  const first = await connect(fakeDaemon(history(), "claude", "claude"));
  try {
    expect(first.recaps()).toEqual([RECAP]);
    first.client.dismissRecap("recap-2");
    expect(first.recaps()).toEqual([]);
  } finally {
    first.client.close();
  }
  const again = await connect(fakeDaemon(history(), "claude", "claude"));
  try {
    expect(again.recaps()).toEqual([]);
  } finally {
    again.client.close();
  }
});

test("a recap another chat's dismissal names by the same seq still shows", async () => {
  localStorage.setItem("cmux.agentPane.recapDismissed", JSON.stringify(["some-other-chat:2"]));
  const { client, recaps } = await connect(
    fakeDaemon(
      record([
        ["mux", "user_message", { text: "hi" }],
        ["mux", "recap", { text: RECAP }],
      ]),
      "claude",
      "claude",
    ),
  );
  try {
    expect(recaps()).toEqual([RECAP]);
  } finally {
    client.close();
  }
});
