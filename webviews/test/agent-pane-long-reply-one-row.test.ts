// l10n-allow-file: test fixture replies, not shipped UI.
//
// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a settled page
// (zero layout shift after first paint, streaming included) within 2x of a derived bound".
//
// A running reply longer than a page: the chat opens on its newest page, which starts inside the reply, and the
// pages above it bring the reply's earlier text. acpmux stamps every chunk of the reply with one segment
// (hub/stream.rs `reply_segment_for`), and the pane names the reply's row by it, so each page's chunks are the same
// row. A page that folded in before the turn's start (`foldOlder`) found the row held and drew its chunks as a row
// of their own, under the first chunk's seq; the page with the turn's start then refolded the reply and gave the
// stamped id to its start, so the row drawn at the bottom took another id (a remount) and the reply drew as two rows
// (settled-page bench, chat_switch.stream: a 1047 px move once the reply outgrew two pages).
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

const START = Date.UTC(2026, 10, 26, 18, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Row = { id: string; kind: string; text?: string };
type Snapshot = { rows: Row[]; canLoadOlder: boolean };

/// Two finished turns, then a running turn whose one reply is `chunks` stamped chunks.
function chat(sessionId: string, chunks: number): { all: Rec[]; reply: string } {
  const steps: [string, string, Record<string, unknown>][] = [];
  const say = (text: string, segment: string) =>
    steps.push([
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId,
          _meta: { acpmux: { segment } },
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
        },
      },
    ]);
  for (let n = 1; n <= 2; n++) {
    steps.push(["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }], ["mux", "turn_started", {}]);
    say(`Answer ${n}.`, `t${n}.b.1`);
    steps.push(["mux", "turn_result", { stopReason: "end_turn" }]);
  }
  steps.push(["mux", "user_message", { text: "The current turn", promptId: "p-now" }], ["mux", "turn_started", {}]);
  let reply = "";
  for (let n = 1; n <= chunks; n++) {
    const word = `w${n} `;
    reply += word;
    say(word, "t3.b.1");
  }
  const all = steps.map(([dir, kind, msg], index) => ({
    sessionId,
    seq: index + 1,
    at: START + index,
    dir,
    kind,
    msg,
  }));
  return { all, reply };
}

/// A stand-in acpmux serving `all` in pages of `limit` records, newest first (hub/paging.rs `events_page`).
function daemon(all: Rec[]) {
  const summary = {
    sessionId: all[0]!.sessionId,
    cwd: "/home/dev/cmux",
    title: "long reply",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 3,
    updatedAt: START,
  };
  const newestPage = (beforeSeq: number, limit: number, kinds?: string[]) => {
    const asked = all.filter(
      (event) => event.seq < beforeSeq && (!kinds || kinds.includes("transcript") || kinds.includes(event.kind)),
    );
    const events = asked.slice(-limit);
    return { events, hasMore: events.length < asked.length };
  };
  return class Socket {
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
        const page = newestPage(Number.POSITIVE_INFINITY, Number(params.limit ?? 400), params.kinds);
        const first = page.events[0];
        const turnOpener =
          first && first.kind !== "user_message" && page.hasMore
            ? ([...all].reverse().find((event) => event.kind === "user_message" && event.seq < first.seq) ?? null)
            : null;
        result = { session: summary, lastSeq: all.length, events: page.events, hasMore: page.hasMore, turnOpener };
      } else if (message.method === "_acpmux/events") {
        const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds : undefined;
        const before = params.beforeSeq === undefined ? Number.POSITIVE_INFINITY : Number(params.beforeSeq);
        result = { ...newestPage(before, Number(params.limit ?? 400), kinds), lastSeq: all.length };
      }
      setTimeout(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }), 0);
    }
  };
}

for (const chunks of [600, 1000]) {
  test(`a running reply of ${chunks} stamped chunks stays one row, its id kept, as every page above it comes in`, async () => {
    const sessionId = `0190a000-0000-7000-8000-0000000c${String(chunks).padStart(4, "0")}`;
    const { all, reply } = chat(sessionId, chunks);
    const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
    const { mockHost } = await import("../src/agent-session/acpmux/mock");
    const Socket = daemon(all);
    const state: { snapshot?: Snapshot } = {};
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (next) => {
        state.snapshot = next as unknown as Snapshot;
      },
      undefined,
      () => new Socket() as unknown as WebSocket,
    );
    try {
      await client.select(sessionId);
      const replies = () => (state.snapshot?.rows ?? []).filter((row) => row.kind === "assistant");
      const opened = replies().at(-1)?.id;
      expect(opened).toBeString();
      const seen: string[][] = [];
      for (let asks = 0; state.snapshot?.canLoadOlder && asks < 20; asks++) {
        await client.loadOlder();
        seen.push(replies().map((row) => `${row.id}:${row.text?.split(" ", 1)[0]}`));
      }
      expect(state.snapshot?.canLoadOlder).toBe(false);
      // The running reply is one row, under the id it opened with, after every page.
      for (const step of seen) expect(step.filter((row) => !row.includes(":Answer")).length).toBe(1);
      const last = replies().at(-1)!;
      expect(last.id).toBe(opened!);
      expect(last.text).toBe(reply);
    } finally {
      client.close();
    }
  });
}
