// The context ring's card reads what fills the window from the chat's usage (Claude Code's /context
// rows, which acpmux forwards on a usage update as `_meta.claude.context`) and when the chat last
// compacted (its compaction row's end). A compaction makes the rows stale, so they go until Claude
// Code counts again; the usage updates between keep them.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { lastCompactedAt } from "../src/agent-session/acpmux/contextBreakdown";

const CHAT = "0190a000-0000-7000-8000-0000000000c9";
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

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events.
function fakeDaemon(history: Recorded[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/app",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
  };
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

const usage = (used: number, meta?: Record<string, unknown>): Step => [
  "in",
  "usage_update",
  {
    method: "session/update",
    params: { update: { sessionUpdate: "usage_update", used, size: 475_000, ...(meta ? { _meta: meta } : {}) } },
  },
];
const ROWS = {
  categories: [
    { id: "system_prompt", name: "System prompt", tokens: 6_200 },
    { id: "messages", name: "Messages", tokens: 90_000 },
  ],
  attachmentTokens: 2_500,
};
const compaction = (state: string): Step => [
  "in",
  "compaction",
  { method: "session/update", params: { update: { sessionUpdate: "compaction", state, preTokens: 111_000 } } },
];

test("the chat's usage carries Claude Code's rows until a compaction, and the compaction's end", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "fix the build" }],
      ["mux", "turn_started", { turnId: "t1" }],
      usage(111_000),
      usage(111_000, { claude: { context: ROWS } }),
    ]),
  );
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.summary?.usage?.breakdown !== undefined, "the rows");
    expect(snapshot.summary.usage).toEqual({ used: 111_000, size: 475_000, breakdown: ROWS });
    expect(lastCompactedAt(snapshot.rows)).toBeUndefined();
    // A model call's usage between two counts keeps the rows.
    daemon.push(record([usage(120_000, { acpmux: { call: true } })], 5));
    await until(() => snapshot.summary.usage.used === 120_000, "the next call");
    expect(snapshot.summary.usage.breakdown).toEqual(ROWS);
    // A compaction: running, then done. The rows go; its end is when it finished.
    daemon.push(record([compaction("running"), compaction("completed")], 6));
    await until(() => lastCompactedAt(snapshot.rows) !== undefined, "the compaction's end");
    expect(lastCompactedAt(snapshot.rows)).toBe(START + 7 * 1000);
    expect(snapshot.summary.usage).toEqual({ used: 120_000, size: 475_000 });
  } finally {
    client.close();
  }
});
