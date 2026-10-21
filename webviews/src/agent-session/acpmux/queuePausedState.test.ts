// A queue paused after a failed turn is one honest state (Leo's live chat, 2026-10-21: "so many
// things wrong"): the chat says which error paused it, and nothing claims to run. acpmux may still
// list the session as running from before the failure; only a turn that starts says it works.
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

type Shown = { isWorking: boolean; summary?: { queuePaused?: boolean; queuePausedError?: string } };

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

test("a paused queue names the turn that paused it and shows nothing running", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    daemon.emit(id, { mux: "turn_error", msg: { error: "stream disconnected", turnId: "t-1" } });
    daemon.emit(id, { mux: "queue_paused", msg: { turnId: "t-1", held: ["p-2"] } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "stream disconnected", turnId: "t-1" } });
    // acpmux still lists the session as running when the queue's pause reaches the pane.
    daemon.touch(id, { status: "running", queuePaused: true });
    await until(() => view.shown.summary?.queuePaused === true);
    expect(view.shown.summary?.queuePausedError).toBe("stream disconnected");
    expect(view.shown.isWorking).toBe(false);
    // Its automatic continuation fails too, and holds nothing new: the note still names the cut.
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "usage limit reached", turnId: "t-2" } });
    daemon.touch(id, { status: "ready", queuePaused: true });
    await until(() => !view.shown.isWorking);
    expect(view.shown.summary?.queuePausedError).toBe("stream disconnected");
  } finally {
    close();
  }
});

test("a turn that failed before its agent started names its error", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    // Such a turn's result has `error` and no `errorText` (`fail_unstarted_turn`).
    daemon.emit(id, { mux: "queue_paused", msg: { turnId: "t-3", held: ["p-4"] } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", error: "agent could not start", turnId: "t-3" } });
    daemon.touch(id, { status: "disconnected", queuePaused: true });
    await until(() => view.shown.summary?.queuePaused === true);
    expect(view.shown.summary?.queuePausedError).toBe("agent could not start");
  } finally {
    close();
  }
});

test("a pause whose turn the pane never saw names the session's last failed turn", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.touch(id, {
      status: "ready",
      queuePaused: true,
      lastTurn: { status: "failed", errorText: "agent process closed", turnId: "t-9", endedAt: 1 },
    });
    await until(() => view.shown.summary?.queuePaused === true);
    expect(view.shown.summary?.queuePausedError).toBe("agent process closed");
  } finally {
    close();
  }
});
