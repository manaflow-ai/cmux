// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a settled page
// (zero layout shift after first paint, streaming included) within 2x of a derived bound".
//
// A hidden chat page holds what lands while it is hidden and draws it when it shows (direct.ts `showChanged`). It
// published that in the next display frame, and a pane draw set from a frame callback is a default-lane render React
// runs after that frame paints: the first frame back drew the chat as it was when hidden, and the next frame added the
// turn that came meanwhile (settled-page bench, workspace_switch.idle: a 254 px jump in every round). Published inside
// `visibilitychange`, a discrete event, the draw commits before the first frame.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let visibility: "visible" | "hidden" = "visible";
// Display frames come only when the test draws one.
let frames = new Map<number, () => void>();
let frameIds = 0;
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.requestAnimationFrame = (run: () => void) => {
    frameIds += 1;
    frames.set(frameIds, run);
    return frameIds;
  };
  scope.cancelAnimationFrame = (id: number) => frames.delete(id);
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
});
const setVisibility = (next: "visible" | "hidden") => {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};
const drawFrame = () => {
  const due = [...frames.values()];
  frames = new Map();
  for (const run of due) run();
};
const settle = async () => {
  for (let n = 0; n < 20; n++) {
    await new Promise((done) => setTimeout(done, 0));
    drawFrame();
  }
};

const SESSION = "0190a000-0000-7000-8000-00000005e0e1";
const START = Date.UTC(2026, 10, 26, 18, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Row = { id: string; kind: string; text?: string };
const reply = (text: string, segment: string): [string, string, Record<string, unknown>] => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: {
      sessionId: SESSION,
      _meta: { acpmux: { segment } },
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  },
];
const turn = (n: number): [string, string, Record<string, unknown>][] => [
  ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
  ["mux", "turn_started", {}],
  reply(`Answer ${n}.`, `t${n}.b.1`),
  ["mux", "turn_result", { stopReason: "end_turn" }],
];
const records = (steps: [string, string, Record<string, unknown>][], from: number): Rec[] =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: SESSION,
    seq: from + index,
    at: START + from + index,
    dir,
    kind,
    msg,
  }));

test("a chat shown again draws the turn that came while it was hidden before its first frame", async () => {
  const seeded = records([...turn(1), ...turn(2)], 1);
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/cmux",
    title: "hidden turn",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 2,
    updatedAt: START,
  };
  let live: { onmessage: ((message: { data: string }) => void) | null } | undefined;
  class Socket {
    readyState = 0;
    onopen: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onmessage: ((message: { data: string }) => void) | null = null;
    constructor() {
      live = this;
      setTimeout(() => {
        this.readyState = 1;
        this.onopen?.();
      }, 0);
    }
    close() {}
    send(text: string) {
      const message = JSON.parse(text) as { id?: number; method: string };
      if (message.id === undefined) return;
      let result: unknown = null;
      if (message.method === "initialize")
        result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      else if (message.method === "_acpmux/watch") result = { sessions: [summary] };
      else if (message.method === "_acpmux/attach")
        result = { session: summary, lastSeq: seeded.length, events: seeded, hasMore: false };
      else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: seeded.length };
      setTimeout(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }), 0);
    }
  }
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { mockHost } = await import("../src/agent-session/acpmux/mock");
  // The app draws in display frames (mountModel.tsx sets `nextFrame`); here a frame runs only when the test draws one.
  AcpmuxDirectClient.scheduleFrame = (run) => {
    const id = (scope.requestAnimationFrame as (run: () => void) => number)(run);
    return () => frames.delete(id);
  };
  const state: { rows: Row[] } = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      state.rows = (next as unknown as { rows: Row[] }).rows;
    },
    undefined,
    () => new Socket() as unknown as WebSocket,
  );
  const users = () => state.rows.filter((row) => row.kind === "user").map((row) => row.text);
  try {
    await client.select(SESSION);
    await settle();
    expect(users()).toEqual(["Question 1", "Question 2"]);

    setVisibility("hidden");
    await settle();
    // A whole turn ends while another workspace shows.
    for (const event of records(turn(3), seeded.length + 1))
      live!.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    await settle();
    // The hidden page drew nothing of it.
    expect(users()).toEqual(["Question 1", "Question 2"]);

    // Shown: the turn is drawn within the show, before any display frame runs.
    setVisibility("visible");
    expect(users()).toEqual(["Question 1", "Question 2", "Question 3"]);
    expect(state.rows.some((row) => row.kind === "assistant" && row.text === "Answer 3.")).toBe(true);
  } finally {
    AcpmuxDirectClient.scheduleFrame = undefined;
    client.close();
  }
});
