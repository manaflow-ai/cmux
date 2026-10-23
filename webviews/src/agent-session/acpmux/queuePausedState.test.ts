// A queue paused after a failed turn runs nothing (Leo's live chat, 2026-10-21: "so many things
// wrong"): acpmux may still list the session as running from before the failure; only a turn that
// starts says it works. The paused note's error is queuePause.ts's.
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

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};

type Shown = { isWorking: boolean; summary?: { queuePaused?: boolean } };

async function pane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const view = { shown: { isWorking: false } as Shown };
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as unknown as Shown;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await until(() => view.shown.summary !== undefined);
  return { daemon, view, until, id: mockHost.sessionId!, close: () => client.close?.() };
}

test("a paused queue shows nothing running while acpmux still lists it running", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    daemon.emit(id, { mux: "turn_error", msg: { error: "stream disconnected", turnId: "t-1" } });
    daemon.emit(id, { mux: "queue_paused", msg: { turnId: "t-1", held: ["p-2"] } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "stream disconnected", turnId: "t-1" } });
    // acpmux still lists the session as running, with its failed turn, when the pause reaches the pane.
    daemon.touch(id, { status: "running", queuePaused: true, turn: { turnId: "t-1" } });
    await until(() => view.shown.summary?.queuePaused === true);
    expect(view.shown.isWorking).toBe(false);
    // A turn that starts while the queue stays paused does work.
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "usage limit reached", turnId: "t-2" } });
    daemon.touch(id, { status: "ready", queuePaused: true });
    await until(() => !view.shown.isWorking);
  } finally {
    close();
  }
});

test("a turn sent now while the queue stays paused shows running", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queue_paused", msg: { turnId: "t-1", held: ["p-2"] } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "stream disconnected", turnId: "t-1" } });
    daemon.touch(id, { status: "ready", queuePaused: true });
    await until(() => view.shown.summary?.queuePaused === true);
    expect(view.shown.isWorking).toBe(false);
    // Its turn's start is not in this page: acpmux's summary names the turn that runs.
    daemon.touch(id, { status: "running", queuePaused: true, turn: { turnId: "t-3" } });
    await until(() => view.shown.isWorking);
    // A summary naming no running turn is from before the failure.
    daemon.touch(id, { status: "running", queuePaused: true, turn: null });
    await until(() => !view.shown.isWorking);
  } finally {
    close();
  }
});
