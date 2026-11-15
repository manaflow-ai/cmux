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
import { settleReact } from "./support/domTeardown";

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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

/// Each test opens its own chat: a chat's kept tail outlives its client (tailCache.ts), and one id
/// with two different histories is no chat acpmux serves.
const chatId = (n: number) => `0190a000-0000-7000-8000-00000000b17${n}`;
const START = Date.UTC(2026, 9, 29, 18, 0, 0);
const OLDER_TURNS = 30;

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Snapshot = { rows: { kind: string; text?: string; items?: { kind: string }[] }[]; canLoadOlder: boolean };
const update = (sessionId: string, update: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId, update },
});

/// OLDER_TURNS short turns, then the current turn: `tools` tool calls, each with `outputBytes` of output.
function chat(sessionId: string, tools: number, outputBytes: number): Rec[] {
  const steps: [string, string, Record<string, unknown>][] = [];
  for (let n = 1; n <= OLDER_TURNS; n++)
    steps.push(
      ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${n}.` } }),
      ],
      ["mux", "turn_result", { stopReason: "end_turn" }],
    );
  steps.push(["mux", "user_message", { text: "The current turn", promptId: "p-now" }], ["mux", "turn_started", {}]);
  const output = "build output line\n".repeat(Math.ceil(outputBytes / 18));
  for (let n = 1; n <= tools; n++)
    steps.push(
      [
        "in",
        "tool_call",
        update(sessionId, {
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
        update(sessionId, {
          sessionUpdate: "tool_call_update",
          toolCallId: `call-${n}`,
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: `${output}${n}` } }],
        }),
      ],
    );
  return steps.map(([dir, kind, msg], index) => ({
    sessionId,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
}

/// A stand-in acpmux serving `all`, each record's JSON size measured once.
function daemon(all: Rec[]) {
  const sizes = all.map((event) => JSON.stringify(event).length);
  const summary = {
    sessionId: all[0]!.sessionId,
    cwd: "/home/dev/cmux",
    title: "coordinator",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: OLDER_TURNS + 1,
    updatedAt: START,
  };
  /// acpmux's `events_page` (hub/paging.rs): the newest records before `beforeSeq` of `kinds`,
  /// ending before their JSON passes `maxBytes`, always at least one.
  const newestPage = (beforeSeq: number, limit: number, maxBytes: number | undefined, kinds?: string[]) => {
    const events: Rec[] = [];
    let bytes = 0;
    let hasMore = false;
    for (let index = Math.min(all.length, beforeSeq - 1) - 1; index >= 0; index--) {
      const event = all[index]!;
      if (kinds && !kinds.includes("transcript") && !kinds.includes(event.kind)) continue;
      if (events.length === limit) {
        hasMore = true;
        break;
      }
      bytes += sizes[index]!;
      if (maxBytes !== undefined && events.length > 0 && bytes > maxBytes) {
        hasMore = true;
        break;
      }
      events.push(event);
    }
    return { events: events.reverse(), hasMore };
  };
  const stats = { historyReads: 0 };
  class Socket {
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
        if (kinds?.includes("transcript")) stats.historyReads += 1;
        const before = params.beforeSeq === undefined ? Number.POSITIVE_INFINITY : Number(params.beforeSeq);
        const page = newestPage(before, Number(params.limit ?? 400), params.maxBytes, kinds);
        result = { events: page.events, hasMore: page.hasMore, lastSeq: all.length };
      }
      setTimeout(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }), 0);
    }
  }
  return { Socket, stats };
}

async function open(all: Rec[]) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { mockHost } = await import("../src/agent-session/acpmux/mock");
  const { Socket, stats } = daemon(all);
  const state: { snapshot?: Snapshot } = {};
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      state.snapshot = next as unknown as Snapshot;
    },
    undefined,
    () => new Socket() as unknown as WebSocket,
  );
  await client.select(all[0]!.sessionId);
  const prompts = () => (state.snapshot?.rows ?? []).filter((row) => row.kind === "user").map((row) => row.text ?? "");
  const tools = () =>
    (state.snapshot?.rows ?? []).reduce(
      (count, row) => count + (row.items ?? []).filter((item) => item.kind === "tool").length,
      0,
    );
  return { client, stats, state, prompts, tools };
}
const everyPrompt = [...Array.from({ length: OLDER_TURNS }, (_, n) => `Question ${n + 1}`), "The current turn"];

test("a restored chat whose current turn outgrows a page shows the turn before it after one ask", async () => {
  // About 12 MB of current turn, the size measured on the reporting machine (5.6 MB and 13.5 MB).
  const TOOLS = 120;
  // 120 outputs of 16 KB outgrow an older page's 1 MiB cap (direct.ts OLDER_PAGE_BYTES), as 4 KB
  // outgrew its 256 KiB cap before, so the first ask still lands inside the current turn.
  const { client, stats, state, prompts, tools } = await open(chat(chatId(1), TOOLS, 16_000));
  try {
    // The open is the current turn's tail, drawn under its prompt.
    expect(prompts()).toEqual(["The current turn"]);
    expect(state.snapshot?.canLoadOlder).toBe(true);

    // One scroll to the top is one bounded page. The active turn's older records are published
    // immediately; the prior turn arrives on a later ask rather than after a whole-turn scan.
    stats.historyReads = 0;
    const started = performance.now();
    await client.loadOlder();
    const took = (performance.now() - started).toFixed(0);
    console.log(`restore-long-turn: first ask ${took} ms, ${stats.historyReads} reads, prompts ${prompts().length}`);
    expect(prompts().at(-1)).toBe("The current turn");
    expect(prompts()).toEqual(["The current turn"]);
    expect(tools()).toBeGreaterThan(0);

    // And the rest keep coming, in order, back to the first turn.
    for (let asks = 0; state.snapshot?.canLoadOlder && asks < 40; asks++) await client.loadOlder();
    expect(state.snapshot?.canLoadOlder).toBe(false);
    expect(prompts()).toEqual(everyPrompt);
    // Every tool call of the current turn is drawn once.
    expect(tools()).toBe(TOOLS);
  } finally {
    client.close();
  }
});

test("a current turn longer than one ask reads is read on by the next ask, from where it stopped", async () => {
  // Each tool output passes an older page's 1 MiB cap (direct.ts OLDER_PAGE_BYTES), so every record is
  // a page of its own. Each ask reads one page and publishes it before the next ask advances the cursor.
  const TOOLS = 12;
  const { client, stats, state, prompts, tools } = await open(chat(chatId(2), TOOLS, 1100 * 1024));
  try {
    expect(prompts()).toEqual(["The current turn"]);
    stats.historyReads = 0;
    await client.loadOlder();
    // The first page is still inside the current turn, but it is visible and the cursor advances.
    // One page for the ask (OLDER_PAGES_PER_ASK), then the next asks' pages read ahead as it lands
    // (OLDER_AHEAD_PAGES, 4), which those asks take from memory.
    expect(stats.historyReads).toBeGreaterThanOrEqual(1);
    expect(stats.historyReads).toBeLessThanOrEqual(1 + 4);
    expect(prompts()).toEqual(["The current turn"]);
    expect(state.snapshot?.canLoadOlder).toBe(true);
    // The next ask goes on from there; it may still be inside the long turn, so keep asking until
    // the preceding turn's opener arrives.
    await client.loadOlder();
    for (let asks = 0; prompts().at(-2) !== `Question ${OLDER_TURNS}` && asks < 50; asks++) {
      if (state.snapshot?.canLoadOlder) await client.loadOlder();
    }
    expect(prompts().at(-2)).toBe(`Question ${OLDER_TURNS}`);
    for (let asks = 0; state.snapshot?.canLoadOlder && asks < 20; asks++) await client.loadOlder();
    expect(prompts()).toEqual(everyPrompt);
    expect(tools()).toBe(TOOLS);
  } finally {
    client.close();
  }
});

test("a titleless completed tool update survives a page boundary until its opener arrives", async () => {
  const id = chatId(3);
  // Past an older page's 1 MiB cap (direct.ts OLDER_PAGE_BYTES): the result is a page of its own.
  const huge = "result\n".repeat(160_000);
  const history: Rec[] = (
    [
      ["mux", "user_message", { text: "Old", promptId: "p-old" }],
      ["mux", "turn_started", {}],
      [
        "in",
        "tool_call",
        update(id, {
          sessionUpdate: "tool_call",
          toolCallId: "boundary-call",
          title: "run old",
          kind: "execute",
          status: "in_progress",
          rawInput: { command: "old" },
        }),
      ],
      [
        "in",
        "tool_call_update",
        update(id, {
          sessionUpdate: "tool_call_update",
          toolCallId: "boundary-call",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: huge } }],
        }),
      ],
      ["mux", "turn_result", { stopReason: "end_turn" }],
      ["mux", "user_message", { text: "Current", promptId: "p-current" }],
      ["mux", "turn_started", {}],
    ] as [string, string, Record<string, unknown>][]
  ).map(([dir, kind, msg], index) => ({
    sessionId: id,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const { client, state } = await open(history);
  try {
    await client.loadOlder();
    await client.loadOlder();
    const tool = state.snapshot?.rows.flatMap((row) => row.items ?? []).find((item) => item.kind === "tool") as
      | {
          tool?: {
            id?: string;
            title?: string;
            kind?: string;
            command?: string;
            inputSummary?: string;
            status?: string;
            output?: string;
          };
        }
      | undefined;
    expect(tool?.tool?.id).toBe("boundary-call");
    expect(tool?.tool?.title).toBe("run old");
    expect(tool?.tool?.kind).toBe("execute");
    expect(tool?.tool?.command).toBe("old");
    expect(tool?.tool?.inputSummary).toContain("old");
    expect(tool?.tool?.status).toBe("completed");
    expect(tool?.tool?.output).toContain("result");
  } finally {
    client.close();
  }
});

test("reused tool ids in different turns remain separate while paging", async () => {
  const id = chatId(4);
  const step = (
    text: string,
    promptId: string,
    output: string,
    finish = true,
  ): [string, string, Record<string, unknown>][] => [
    ["mux", "user_message", { text, promptId }],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update(id, {
        sessionUpdate: "tool_call",
        toolCallId: "reused",
        title: text,
        kind: "execute",
        status: "in_progress",
        rawInput: { command: text },
      }),
    ],
    ...(finish
      ? [
          [
            "in",
            "tool_call_update",
            update(id, {
              sessionUpdate: "tool_call_update",
              toolCallId: "reused",
              title: text,
              kind: "execute",
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: output } }],
            }),
          ] as [string, string, Record<string, unknown>],
        ]
      : []),
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ];
  const steps = [...step("Old", "p-old", "old output"), ...step("Old", "p-current", "current output", false)];
  const history: Rec[] = steps.map(([dir, kind, msg], index) => ({
    sessionId: id,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const { client, state } = await open(history);
  try {
    for (let asks = 0; state.snapshot?.canLoadOlder && asks < 8; asks++) await client.loadOlder();
    const tools = state.snapshot?.rows.flatMap((row) => row.items ?? []).filter((item) => item.kind === "tool") ?? [];
    expect(tools).toHaveLength(2);
    expect((tools[0] as any).tool?.output).toBe("old output");
    expect((tools[1] as any).tool?.status).toBe("in_progress");
  } finally {
    client.close();
  }
});

test("assistant fragments split by an older page rejoin at the message boundary", async () => {
  const id = chatId(5);
  const huge = "tail\n".repeat(80_000);
  const steps: [string, string, Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Current", promptId: "p-current" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      update(id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "message-boundary",
        content: { type: "text", text: "**hello " },
      }),
    ],
    [
      "in",
      "agent_message_chunk",
      update(id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "message-boundary",
        content: { type: "text", text: `world** ${huge}` },
      }),
    ],
  ];
  const history: Rec[] = steps.map(([dir, kind, msg], index) => ({
    sessionId: id,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const { client, state } = await open(history);
  try {
    await client.loadOlder();
    const assistants = state.snapshot?.rows.filter((row) => row.kind === "assistant") ?? [];
    expect(assistants).toHaveLength(1);
    expect(assistants[0]?.text).toContain("**hello world**");
  } finally {
    client.close();
  }
});
