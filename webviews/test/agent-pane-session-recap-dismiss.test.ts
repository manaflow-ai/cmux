// l10n-allow-file: test fixture recap text, not shipped UI.
// A session recap's × (RecapNote): the client drops the recap's row, so no empty row slot stays
// in the transcript, and the recap stays dismissed on this device when the chat attaches again.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, rebuildCut, REBUILD_WINDOW } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { SINCE_DIVIDER } from "../src/agent-session/acpmux/model";

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

/// A daemon over a fake socket for a chat on `harness`: attach answers with `history` and the
/// reader's seen cursor (`readThrough`, none: an acpmux that keeps no cursor); `push` sends live events.
function fakeDaemon(
  history: Recorded[],
  harness: string,
  family: string,
  options: {
    older?: Recorded[];
    lastReturn?: { since: number; turns: number };
    readThrough?: number;
  } = {},
) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/app",
    title: "x",
    harness,
    family,
    status: "idle",
    lastReturn: options.lastReturn,
  };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return {
          session,
          lastSeq: lastSeq(),
          events: history,
          hasMore: Boolean(options.older?.length),
          ...(options.readThrough !== undefined && { readThrough: options.readThrough }),
        };
      case "_acpmux/events":
        return { events: options.older ?? [], hasMore: false, more: false, lastSeq: lastSeq() };
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
  const lag = () =>
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [CHAT] } }),
    });
  return { open, push, lag };
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
    (snapshot.rows as AcpmuxRow[]).flatMap((row) => {
      const recap = row.recap ?? row.since?.recap;
      return recap ? [recap.text] : [];
    });
  return { client, recaps, snapshot: () => snapshot as AcpmuxSnapshot };
}

const RECAP = "You were fixing the flaky login test; the retry fix is in and CI is running.";
/// An agent's reply: a row the seen cursor counts (jumpControl.ts `countsUnseen`), so "New since you
/// looked" goes above it when the reader saw through an earlier record.
const reply = (text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];

for (const mode of ["replay", "fed"] as const)
  test(`${mode} rebuilds reconstruct the latest recap in the requested event window`, () => {
    const events = record([
      ["mux", "user_message", { text: "fix the login test" }],
      ["mux", "recap", { text: "An older recap." }],
      ["mux", "recap", { text: RECAP }],
    ]);
    let shown: AcpmuxSnapshot | undefined;
    const listener = (snapshot: AcpmuxSnapshot) => {
      shown = snapshot;
    };
    const client =
      mode === "replay" ? AcpmuxDirectClient.replay(CHAT, events, listener) : AcpmuxDirectClient.fed(CHAT, listener);
    const recaps = () => shown?.rows.flatMap((row) => (row.recap ? [row.recap.text] : [])) ?? [];
    try {
      if (mode === "replay") {
        client.seekReplay(3);
        expect(recaps()).toEqual([RECAP]);
        client.seekReplay(2);
        expect(recaps()).toEqual(["An older recap."]);
        client.seekReplay(3);
        expect(recaps()).toEqual([RECAP]);
      } else {
        client.feed(events, "snapshot");
        expect(recaps()).toEqual([RECAP]);
        client.feed(events, "snapshot");
        expect(recaps()).toEqual([RECAP]);
      }
    } finally {
      client.close();
    }
  });

test("replayed and live recap updates replace the previous summary", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "fix the login test" }],
      ["mux", "recap", { text: "First recap." }],
      ["mux", "recap", { text: "Second recap." }],
      ["mux", "recap", { text: RECAP }],
    ]),
    "claude",
    "claude",
  );
  const { client, recaps } = await connect(daemon);
  try {
    expect(recaps()).toEqual([RECAP]);
    daemon.push(record([["mux", "recap", { text: "The latest state. Next: check the result." }]], 5));
    await until(() => recaps().includes("The latest state. Next: check the result."), "the latest recap");
    expect(recaps()).toEqual(["The latest state. Next: check the result."]);
    client.dismissRecap("recap-5", `${CHAT}:5`);
    expect(recaps()).toEqual([]);
  } finally {
    client.close();
  }
});

test("a dismissed latest recap does not expose older summaries when attaching again", async () => {
  localStorage.setItem("cmux.agentPane.recapDismissed", JSON.stringify([`${CHAT}:3`]));
  const { client, recaps } = await connect(
    fakeDaemon(
      record([
        ["mux", "user_message", { text: "fix the login test" }],
        ["mux", "recap", { text: "An older recap." }],
        ["mux", "recap", { text: RECAP }],
      ]),
      "claude",
      "claude",
    ),
  );
  try {
    expect(recaps()).toEqual([]);
  } finally {
    client.close();
  }
});

test("recaps attached to the unread divider still replace and dismiss as one summary", async () => {
  // The reader saw through the prompt; the reply after it is new, so the line goes above it.
  const { client, recaps, snapshot } = await connect(
    fakeDaemon(
      record([
        ["mux", "user_message", { text: "fix the login test" }],
        ["mux", "recap", { text: "An older recap.", since: 1 }],
        ["mux", "recap", { text: RECAP, since: 1 }],
        reply("The retry fix is in."),
      ]),
      "claude",
      "claude",
      { lastReturn: { since: 1, turns: 2 }, readThrough: 1 },
    ),
  );
  try {
    expect(recaps()).toEqual([RECAP]);
    expect(snapshot().rows.find((row) => row.kind === SINCE_DIVIDER)?.since?.recap?.text).toBe(RECAP);
    client.dismissRecap(SINCE_DIVIDER, `${CHAT}:3`);
    expect(recaps()).toEqual([]);
  } finally {
    client.close();
  }
});

for (const dismissed of [false, true])
  test(`paging an older recap never replaces or revives the latest summary, dismissed=${dismissed}`, async () => {
    const { client, recaps } = await connect(
      fakeDaemon(
        record(
          [
            ["mux", "user_message", { text: "fix the login test" }],
            ["mux", "recap", { text: RECAP }],
          ],
          10,
        ),
        "claude",
        "claude",
        {
          older: record([["mux", "recap", { text: "An older page's recap." }]], 2),
        },
      ),
    );
    try {
      if (dismissed) client.dismissRecap("recap-11", `${CHAT}:11`);
      await client.loadOlder();
      expect(recaps()).toEqual(dismissed ? [] : [RECAP]);
    } finally {
      client.close();
    }
  });

test("dismissing a recap drops its row, and it stays dismissed when the chat attaches again", async () => {
  const history = () =>
    record([
      ["mux", "user_message", { text: "fix the login test" }],
      ["mux", "recap", { text: RECAP, awayMs: 360_000 }],
    ]);
  const first = await connect(fakeDaemon(history(), "claude", "claude"));
  try {
    expect(first.recaps()).toEqual([RECAP]);
    first.client.dismissRecap("recap-2", `${CHAT}:2`);
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

test("a press on another chat's recap with the same seq leaves this chat's recap in place", async () => {
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
    // The chat a switch still showed: its key names the other chat.
    client.dismissRecap("recap-2", "the-chat-switched-from:2");
    expect(recaps()).toEqual([RECAP]);
    expect(JSON.parse(localStorage.getItem("cmux.agentPane.recapDismissed") ?? "[]")).toEqual([
      "the-chat-switched-from:2",
    ]);
  } finally {
    client.close();
  }
});

for (const attached of [false, true])
  for (const dismissed of [false, true])
    test(`a partial refold preserves the recap watermark, attached=${attached}, dismissed=${dismissed}`, async () => {
      const steps: Step[] = [
        ["mux", "user_message", { text: "Review the workspace change." }],
        ["mux", "recap", { text: RECAP, ...(attached ? { since: 1 } : {}) }],
        ...Array.from({ length: REBUILD_WINDOW + 200 }, (_, index): Step =>
          index % 100 === 0
            ? ["mux", "user_message", { text: `Background turn ${index / 100}.` }]
            : index % 100 === 1
              ? reply(`Background reply ${Math.floor(index / 100)}.`)
              : index % 100 === 99
                ? ["mux", "turn_result", { status: "completed" }]
                : ["mux", "noop", {}],
        ),
      ];
      const history = record(steps);
      const nextSeq = history.at(-1)!.seq + 1;
      expect(rebuildCut(history, nextSeq)).toBeGreaterThan(0);
      // Attached: the reader saw through the first prompt, so the line goes above the replies after it.
      const daemon = fakeDaemon(
        history,
        "claude",
        "claude",
        attached ? { lastReturn: { since: 1, turns: 1 }, readThrough: 1 } : {},
      );
      const { client, recaps, snapshot } = await connect(daemon);
      try {
        expect(recaps()).toEqual([RECAP]);
        expect(snapshot().rows.some((row) => row.since?.recap)).toBe(attached);
        if (dismissed) client.dismissRecap(attached ? SINCE_DIVIDER : "recap-2", `${CHAT}:2`);
        daemon.lag();
        await until(() => snapshot().connection === "resynced", "the partial refold");
        expect(recaps()).toEqual(dismissed ? [] : [RECAP]);
        daemon.push(
          record(
            [["mux", "recap", { text: "The latest result after refolding.", ...(attached ? { since: 1 } : {}) }]],
            nextSeq,
          ),
        );
        await until(() => recaps().includes("The latest result after refolding."), "the replacement recap");
        expect(recaps()).toEqual(["The latest result after refolding."]);
      } finally {
        client.close();
      }
    });
