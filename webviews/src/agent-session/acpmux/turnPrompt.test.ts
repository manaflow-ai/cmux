// The snapshot names the running turn's prompt (direct.ts `turnPrompt`), which a Stop kept through a
// reconnect is scoped to (stopThroughReconnect.ts): acpmux's continuation `P~resume-n` counts as
// `P`, and a turn's prompt ends with it. Its own file, as stopping.test.ts: the client's snapshots
// run outside the React act() scope the hook tests set up.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
});

test("the snapshot names the running turn's prompt, its continuation's as the cut turn's", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  // A fresh mock daemon numbers its records from 1: a tail an earlier test's client kept for this
  // chat (higher numbers) would read them as seen.
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as {
    emit: (target: string, step: unknown) => void;
    touch: (target: string, fields: Record<string, unknown>) => void;
  };
  const view = { shown: { isWorking: false } as { isWorking: boolean; turnPrompt?: string; summary?: unknown } };
  const waiters: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };

  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as unknown as typeof view.shown;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const id = mockHost.sessionId!;
  try {
    await until(() => view.shown.summary !== undefined);
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started", msg: { promptId: "p1", turnId: "t1" } });
    await until(() => view.shown.turnPrompt === "p1");
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", stopReason: "cancelled", turnId: "t1" } });
    daemon.touch(id, { status: "ready" });
    await until(() => !view.shown.isWorking);
    expect(view.shown.turnPrompt).toBeUndefined();
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started", msg: { promptId: "p1~resume-1", turnId: "t2" } });
    await until(() => view.shown.isWorking);
    expect(view.shown.turnPrompt).toBe("p1");
    // A turn that ends takes its prompt along, and one that opens without naming its prompt is no
    // known one's, never the turn before's (Codex re-review of #27804 at da4dc25, P1).
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled", turnId: "t2" } });
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t3" } });
    await until(() => view.shown.isWorking);
    expect(view.shown.turnPrompt).toBeUndefined();
  } finally {
    client.close?.();
  }
});
