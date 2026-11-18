// l10n-allow-file: test fixture titles, not shipped UI.
// A parked page draws nothing for other chats' changes, though it reads visible (Lawrence, 2026-11-18:
// dropped frames scrolling a short chat on a large real-world profile; Leo: "Why should non visible thing
// even affect the renderer thread anyways?"). The New Tab spare and a closed chat kept for Reopen wait in
// an off-screen parking view, and the native side tells Chromium they are visible so each has painted
// when taken; their `visibilityState` reads visible, so every change of any chat drew them in the
// renderer the shown chats share. The host now tells the page it is parked (`acpmux-parked`,
// AgentPaneView.setParked), and its data work waits as a hidden page's does. Taken, it draws what it left
// in that same turn, so the adoption that follows never draws the list as it was when it parked.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { settleReact } from "./support/domTeardown";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
let visibility: "visible" | "hidden" = "visible";
const savedSchedule = AcpmuxDirectClient.scheduleFrame;
let frames: (() => void)[] = [];

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(async () => {
  AcpmuxDirectClient.scheduleFrame = savedSchedule;
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

beforeEach(() => {
  // Each test is a fresh page: its chat starts at seq 1, so a tail an earlier test's client kept of
  // the same chat id would stand in front of it (session ids are never reused in the app).
  resetKeptTailsForTests();
  frames = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
});

function flushFrames(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
}

const SESSIONS = 1000;
const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const SELECTED = id(1);
const summary = (n: number, status = "idle") => ({
  sessionId: id(n),
  cwd: `/home/dev/project-${n % 40}`,
  title: `Chat ${n}`,
  harness: "claude",
  family: "claude",
  status,
  turnCount: 12,
  updatedAt: 1_000_000 + n,
});

/// A long transcript: 400 records of user prompts and agent replies.
const transcript = Array.from({ length: 400 }, (_, i) => {
  const seq = i + 1;
  return i % 2 === 0
    ? {
        sessionId: SELECTED,
        seq,
        at: seq,
        dir: "mux",
        kind: "user_message",
        msg: { prompt: [{ type: "text", text: `Question ${seq}` }] },
      }
    : {
        sessionId: SELECTED,
        seq,
        at: seq,
        dir: "in",
        kind: "transcript",
        msg: {
          method: "session/update",
          params: {
            sessionId: SELECTED,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `Answer ${seq} `.repeat(20) },
            },
          },
        },
      };
});

class FakeAcpmux {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    if (message.id === undefined) return;
    const result =
      message.method === "initialize"
        ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } }
        : message.method === "_acpmux/watch"
          ? { sessions: Array.from({ length: SESSIONS }, (_, n) => summary(n + 1)) }
          : message.method === "_acpmux/attach"
            ? { session: summary(1), lastSeq: transcript.length, events: transcript, hasMore: false }
            : message.method === "_acpmux/events"
              ? { events: [], hasMore: false, lastSeq: transcript.length }
              : {};
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
  }
  notify(method: string, params: unknown): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }
  close(): void {
    this.readyState = 3;
  }
}

async function openPane(): Promise<{ socket: FakeAcpmux; client: AcpmuxDirectClient; snapshots: () => number }> {
  const socket = new FakeAcpmux();
  let count = 0;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://coalesce.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type === "snapshot") count += 1;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
  return { socket, client, snapshots: () => count };
}

/// One change of each of `chats` other running chats, as acpmux sends them.
function burst(socket: FakeAcpmux, chats: number, round: number): void {
  for (let n = 0; n < chats; n++) {
    const chat = 2 + ((n + round * chats) % (SESSIONS - 1));
    socket.notify("_acpmux/session_changed", {
      sessionId: id(chat),
      session: { ...summary(chat, "running"), updatedAt: 2_000_000 + round * chats + n },
      kind: "permission_resolved",
      recordKind: "permission_auto",
      seq: 10 + round,
    });
  }
}

function setParked(parked: boolean): void {
  dom.window.dispatchEvent(new dom.window.CustomEvent("acpmux-parked", { detail: { parked } }));
}

test("a parked pane draws no other chat's change, and draws them in the turn it is taken", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    expect(document.visibilityState).toBe("visible");
    setParked(true);
    const before = snapshots();
    for (let round = 0; round < 5; round++) {
      burst(socket, 30, round);
      flushFrames();
    }
    expect(snapshots() - before, "a parked pane's draws for other chats' changes").toBe(0);
    setParked(false);
    expect(snapshots() - before, "the taken pane's draw of what it left, in the same turn").toBe(1);
    burst(socket, 30, 9);
    flushFrames();
    expect(snapshots() - before, "a taken pane draws other chats' changes again").toBe(2);
  } finally {
    setParked(false);
    client.close();
  }
});
