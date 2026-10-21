// l10n-allow-file: test fixture prompts and tool titles, not shipped UI.
// The running turn's line says what the turn has spent so far, as Claude desktop's does: the
// working dots, the time, then this turn's tokens ("Working for 5m 54s · 2.1M tokens"). Claude Code
// reports each model call's usage as it lands (acpmux `usage_update`, claude_stdio/inbound.rs: the
// call's input, cache and output tokens), so the turn's tokens are the sum of the calls since its
// `turn_started`. A chat attached after its turn started has not seen every call, and a harness
// whose usage is the context it holds (not one call's) cannot be summed: both show the time alone.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  WorkingCountsContext,
  WorkingFor,
  workingTokens,
  type WorkingCounts,
} from "../src/agent-session/acpmux/conversation/WorkingFor";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const usage = (used: number, size = 200_000): Step => [
  "in",
  "usage_update",
  update({ sessionUpdate: "usage_update", used, size }),
];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events.
function fakeDaemon(history: ReturnType<typeof record>, harness = "claude", family = "claude") {
  let socket: any;
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness, family, status: "running" };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const events = history.filter((event) => event.seq > after && event.seq < before);
        return { events, hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      }
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
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: ReturnType<typeof record>) => {
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
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, snapshot: () => snapshot };
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

test("a Claude turn's tokens are the sum of its model calls since it started, live", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "fix the build" }],
      ["mux", "turn_started", {}],
      // Claude Code's window is 0 until its first result: the call still counts.
      usage(41_200, 0),
      usage(43_800),
    ]),
  );
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBe(85_000);
    daemon.push(record([usage(46_000)], 5));
    await settle();
    expect(snapshot().turnTokens).toBe(131_000);
    // The turn ends: no running line, nothing to count.
    daemon.push(record([["mux", "turn_result", { status: "completed" }]], 6));
    await settle();
    expect(snapshot().turnTokens).toBeUndefined();
    // The next turn counts from zero.
    daemon.push(record([["mux", "user_message", { text: "again" }], ["mux", "turn_started", {}], usage(50_000)], 7));
    await settle();
    expect(snapshot().turnTokens).toBe(50_000);
  } finally {
    client.close();
  }
});

test("a chat attached mid-turn, without the turn's start, shows no tokens it cannot add up", async () => {
  const daemon = fakeDaemon(record([usage(41_200), usage(43_800)], 30));
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a harness whose usage is its context, not one call's, shows the time alone", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "fix the build" }],
      ["mux", "turn_started", {}],
      usage(41_200),
      usage(43_800),
    ]),
    "codex",
    "codex",
  );
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
  } finally {
    client.close();
  }
});

const status: AcpmuxRow = { id: "working", kind: "working", version: 1, at: START };
const counts = (extra: Partial<WorkingCounts> = {}): WorkingCounts => ({
  agents: 0,
  commands: 0,
  openAgents: () => {},
  openCommands: () => {},
  ...extra,
});
const drawn = (row: AcpmuxRow, value: WorkingCounts) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={value}>
      <WorkingFor row={row} now={() => START + 354_000} />
    </WorkingCountsContext.Provider>,
  )
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("the line reads the time, then the turn's tokens, after the working dots", () => {
  expect(drawn(status, counts({ tokens: 2_140_000 }))).toBe("Working for 5m 54s · 2.1M tokens");
  expect(drawn({ ...status, doing: "bun test" }, counts({ tokens: 840_000 }))).toBe("bun test 5m 54s · 840K tokens");
  // Before the first call reports, or with no token data, the time stands alone.
  expect(drawn(status, counts())).toBe("Working for 5m 54s");
  expect(drawn(status, counts({ tokens: 0 }))).toBe("Working for 5m 54s");
  // The background counts follow the tokens.
  expect(drawn(status, counts({ tokens: 2_140_000, agents: 2 }))).toBe("Working for 5m 54s · 2.1M tokens · 2 agents");
});

test("tokens are compact in the pane's language", () => {
  expect(workingTokens(translatorFor("en"), "en", 2_140_000)).toBe("2.1M tokens");
  expect(workingTokens(translatorFor("en"), "en", 1)).toBe("1 token");
  const german = new Intl.NumberFormat("de", { notation: "compact", maximumFractionDigits: 1 }).format(2_140_000);
  expect(workingTokens(translatorFor("de"), "de", 2_140_000)).toContain(german);
});
