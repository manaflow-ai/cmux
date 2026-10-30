// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and command output, not shipped UI.
//
// Leo, 2026-10-29: "I can't fucking scroll up past the current fucking turn after restarting ...
// the scroll up thing was because it still took thirty fucking seconds to load anything."
//
// After a restart the pane holds nothing of the chat: it opens on one attach page (128 KiB), and a
// coordinator's current turn is often far larger than that (thousands of tool calls, megabytes of
// output). The page starts in the middle of that turn, so the turn's prompt is drawn first (the
// turn opener) and every older page the reader's scroll asks for is more of the same turn, which
// draws below the prompt and nothing above it. Older turns appear only once a read has gone past the
// turn's start. An ask that stops partway through the turn (a page cap) shows the reader nothing new
// at the top, and each such ask redrew the whole transcript.
//
// This restores such a chat through the real client and holds it to what one scroll to the top
// owes the reader: the turn before the current one is above the current turn's prompt after ONE ask
// for older history, and the turns keep coming, in order, back to the first.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const CHAT = "0190a000-0000-7000-8000-00000000b17e";
const START = Date.UTC(2026, 9, 29, 18, 0, 0);
const OLDER_TURNS = 30;
/// Tool calls in the current turn, each with a few KB of output: about 12 MB, the size of the
/// current turns measured on the reported machine (5.6 MB and 13.5 MB).
const CURRENT_TOOLS = 1500;

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { sessionId: CHAT, update } });
const steps: [string, string, Record<string, unknown>][] = [];
for (let n = 1; n <= OLDER_TURNS; n++)
  steps.push(
    ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${n}.` } }),
    ],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  );
steps.push(["mux", "user_message", { text: "The current turn", promptId: "p-now" }], ["mux", "turn_started", {}]);
const output = "build output line\n".repeat(220);
for (let n = 1; n <= CURRENT_TOOLS; n++)
  steps.push(
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: `call-${n}`,
        title: `swift build ${n}`,
        kind: "execute",
        status: "in_progress",
        rawInput: { command: `swift build --target T${n}` },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: `call-${n}`,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: `${output}${n}` } }],
      }),
    ],
  );
const all: Rec[] = steps.map(([dir, kind, msg], index) => ({
  sessionId: CHAT,
  seq: index + 1,
  at: START + index * 1000,
  dir,
  kind,
  msg,
}));

/// acpmux's `events_page` (hub/paging.rs): the newest records before `beforeSeq` of `kinds`, ending
/// before their JSON passes `maxBytes`, always at least one.
const newestPage = (beforeSeq: number, limit: number, maxBytes: number | undefined, kinds?: string[]) => {
  const events: Rec[] = [];
  let bytes = 0;
  let hasMore = false;
  for (let index = all.length - 1; index >= 0; index--) {
    const event = all[index]!;
    if (event.seq >= beforeSeq) continue;
    if (kinds && !kinds.includes("transcript") && !kinds.includes(event.kind)) continue;
    if (events.length === limit) {
      hasMore = true;
      break;
    }
    bytes += JSON.stringify(event).length;
    if (maxBytes !== undefined && events.length > 0 && bytes > maxBytes) {
      hasMore = true;
      break;
    }
    events.push(event);
  }
  return { events: events.reverse(), hasMore };
};
const summary = {
  sessionId: CHAT,
  cwd: "/home/dev/cmux",
  title: "coordinator",
  harness: "claude",
  family: "claude",
  status: "idle",
  turnCount: OLDER_TURNS + 1,
  updatedAt: START,
};
let historyReads = 0;
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  constructor() {
    setTimeout(() => {
      this.readyState = 1;
      this.onopen?.();
    }, 0);
  }
  close() {}
  send(text: string) {
    const message = JSON.parse(text) as { id?: number; method: string; params?: Record<string, any> };
    if (message.id === undefined) return;
    const params = message.params ?? {};
    let result: unknown = null;
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: [summary] };
    else if (message.method === "_acpmux/attach") {
      const page = newestPage(Number.POSITIVE_INFINITY, Number(params.limit ?? 400), params.maxBytes, params.kinds);
      result = { session: summary, lastSeq: all.length, events: page.events, hasMore: page.hasMore };
    } else if (message.method === "_acpmux/events") {
      const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds : undefined;
      if (kinds?.includes("transcript")) historyReads += 1;
      const before = params.beforeSeq === undefined ? Number.POSITIVE_INFINITY : Number(params.beforeSeq);
      const page = newestPage(before, Number(params.limit ?? 400), params.maxBytes, kinds);
      result = { events: page.events, hasMore: page.hasMore, lastSeq: all.length };
    }
    setTimeout(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }), 0);
  }
}

type Snapshot = { rows: { kind: string; text?: string }[]; canLoadOlder: boolean };

test("a restored chat whose current turn outgrows a page shows the turn before it after one ask", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { mockHost } = await import("../src/agent-session/acpmux/mock");
  let snapshot: Snapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next as unknown as Snapshot;
    },
    undefined,
    () => new Daemon() as unknown as WebSocket,
  );
  try {
    await client.select(CHAT);
    const prompts = () => (snapshot?.rows ?? []).filter((row) => row.kind === "user").map((row) => row.text ?? "");
    // The open is the current turn's tail, drawn under its prompt.
    expect(prompts()).toEqual(["The current turn"]);
    expect(snapshot?.canLoadOlder).toBe(true);

    // One scroll to the top is one ask. The turn before the current one is above its prompt.
    historyReads = 0;
    const started = performance.now();
    await client.loadOlder();
    const firstAsk = performance.now() - started;
    console.log(
      `restore-long-turn: first ask ${firstAsk.toFixed(0)} ms, ${historyReads} reads, prompts ${prompts().length}`,
    );
    expect(prompts().at(-1)).toBe("The current turn");
    expect(prompts().at(-2)).toBe(`Question ${OLDER_TURNS}`);

    // And the rest keep coming, in order, back to the first turn.
    for (let asks = 0; snapshot?.canLoadOlder && asks < 20; asks++) await client.loadOlder();
    expect(snapshot?.canLoadOlder).toBe(false);
    expect(prompts()).toEqual([...Array.from({ length: OLDER_TURNS }, (_, n) => `Question ${n + 1}`), "The current turn"]);
    // Every tool call of the current turn is drawn once.
    const tools = (snapshot?.rows ?? []).filter((row) => row.kind === "tool").length;
    expect(tools).toBe(CURRENT_TOOLS);
  } finally {
    client.close();
  }
});
