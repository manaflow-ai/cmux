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

test("a paused queue names the failed turn's error and shows nothing running", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  let shown: Shown = { isWorking: false };
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot as unknown as Shown;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const id = mockHost.sessionId!;
  try {
    await until(() => shown.summary !== undefined);
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => shown.isWorking);
    daemon.emit(id, { mux: "turn_error", msg: { error: "agent process closed" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", errorText: "agent process closed" } });
    // acpmux still lists the session as running when the queue's pause reaches the pane.
    daemon.touch(id, { status: "running", queuePaused: true });
    await until(() => shown.summary?.queuePaused === true);
    expect(shown.summary?.queuePausedError).toBe("agent process closed");
    expect(shown.isWorking).toBe(false);
    // A turn that starts meanwhile (a prompt sent now) does run.
    daemon.emit(id, { mux: "turn_started" });
    await until(() => shown.isWorking);
  } finally {
    client.close?.();
  }
});
