// The pane's view marker must belong to the selected session. A delayed attach from a chat the
// reader left must not prevent visibility changes from reaching the chat now on screen.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const SESSION_A = "view-race-a";
const SESSION_B = "view-race-b";
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
let visibility: "visible" | "hidden" = "visible";

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    get: () => visibility,
  });
});

afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Message = { id?: number; method: string; params?: Record<string, unknown> };
type Reply = { jsonrpc: "2.0"; id: number; result: unknown };

const summary = (sessionId: string) => ({
  sessionId,
  cwd: "/home/dev/project",
  title: sessionId,
  harness: "codex",
  status: "idle",
  updatedAt: 1,
});

/** A tiny acpmux adapter with one deliberately deferred attach. */
class DeferredAcpmuxSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  holdA = false;
  holdViewA = false;
  attachCounts = new Map<string, number>();
  views: { sessionId: string; visible: boolean }[] = [];
  private heldA?: Message;
  private heldViewA?: Message;
  private attachWaiters: { sessionId: string; count: number; resolve: () => void }[] = [];
  private viewWaiters: { sessionId: string; visible: boolean; resolve: () => void }[] = [];

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/attach") {
      const count = (this.attachCounts.get(sessionId) ?? 0) + 1;
      this.attachCounts.set(sessionId, count);
      for (const waiter of this.attachWaiters.slice())
        if (waiter.sessionId === sessionId && count >= waiter.count) {
          this.attachWaiters.splice(this.attachWaiters.indexOf(waiter), 1);
          waiter.resolve();
        }
      if (sessionId === SESSION_A && this.holdA) {
        this.heldA = message;
        return;
      }
    }
    if (message.method === "_acpmux/view") {
      this.views.push({ sessionId, visible: message.params?.visible === true });
      for (const waiter of this.viewWaiters.slice())
        if (waiter.sessionId === sessionId && waiter.visible === message.params?.visible) {
          this.viewWaiters.splice(this.viewWaiters.indexOf(waiter), 1);
          waiter.resolve();
        }
      if (sessionId === SESSION_A && this.holdViewA) {
        this.heldViewA = message;
        return;
      }
    }
    queueMicrotask(() => this.reply(message));
  }

  close(): void {
    this.readyState = 3;
  }

  waitForAttach(sessionId: string, count: number): Promise<void> {
    if ((this.attachCounts.get(sessionId) ?? 0) >= count) return Promise.resolve();
    return new Promise((resolve) => this.attachWaiters.push({ sessionId, count, resolve }));
  }

  releaseA(): void {
    const message = this.heldA;
    this.heldA = undefined;
    if (!message) throw new Error("session A attach was not held");
    this.reply(message);
  }

  waitForView(sessionId: string, visible: boolean): Promise<void> {
    if (this.views.some((view) => view.sessionId === sessionId && view.visible === visible)) return Promise.resolve();
    return new Promise((resolve) => this.viewWaiters.push({ sessionId, visible, resolve }));
  }

  releaseViewA(): void {
    const message = this.heldViewA;
    this.heldViewA = undefined;
    if (!message) throw new Error("session A view was not held");
    this.reply(message);
  }

  private reply(message: Message): void {
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    const result =
      message.method === "initialize"
        ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: ["_acpmux/view"] } } }
        : message.method === "_acpmux/watch"
          ? { sessions: [summary(SESSION_A), summary(SESSION_B)] }
          : message.method === "_acpmux/attach"
            ? { session: summary(sessionId), lastSeq: 0, events: [] }
            : message.method === "_acpmux/events"
              ? { events: [], hasMore: false, lastSeq: 0 }
              : {};
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result } satisfies Reply) });
  }
}

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

test("a stale attach cannot suppress view updates for the newly selected session", async () => {
  const socket = new DeferredAcpmuxSocket();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://view-race.invalid/",
      token: "test",
      sessionId: SESSION_A,
    },
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    socket.holdA = true;
    const staleSelection = client.select(SESSION_A);
    await socket.waitForAttach(SESSION_A, 2);
    setVisibility("hidden");
    await client.select(SESSION_B);

    socket.holdA = false;
    socket.releaseA();
    await staleSelection;
    setVisibility("visible");
    await socket.waitForView(SESSION_B, true);

    expect(socket.views).toContainEqual({ sessionId: SESSION_B, visible: true });
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("a stale view acknowledgement cannot suppress updates for the newly selected session", async () => {
  const socket = new DeferredAcpmuxSocket();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://view-race.invalid/",
      token: "test",
      sessionId: SESSION_A,
    },
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    socket.holdViewA = true;
    setVisibility("hidden");
    await socket.waitForView(SESSION_A, false);
    await client.select(SESSION_B);

    socket.holdViewA = false;
    socket.releaseViewA();
    setVisibility("visible");
    await socket.waitForView(SESSION_B, true);

    expect(socket.views).toContainEqual({ sessionId: SESSION_B, visible: true });
  } finally {
    client.close();
    setVisibility("visible");
  }
});
