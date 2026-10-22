// Stop and Esc are seen to take (Leo, 2026-10-21: "ALSO THE ESC THING IDK IF IM ACTUALLY STOPPING
// YOU WITH THESE"): from the Stop until the turn ends, the snapshot says it is stopping, and the
// turn's end takes that away.
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
  send: (raw: string) => void;
};

type Shown = { isWorking: boolean; stopping?: true; summary?: unknown };

test("Stop says it is stopping until the turn ends", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  // The agent takes its time with the cancel: this daemon ends the turn when the test says.
  const cancels: string[] = [];
  const send = daemon.send.bind(socket);
  daemon.send = (raw) => {
    if ((JSON.parse(raw) as { method?: string }).method === "session/cancel") cancels.push(raw);
    else send(raw);
  };
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
  const id = mockHost.sessionId!;
  try {
    await until(() => view.shown.summary !== undefined);
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    expect(view.shown.stopping).toBeUndefined();

    await client.cancel();
    expect(cancels).toHaveLength(1);
    await until(() => view.shown.stopping === true);
    expect(view.shown.isWorking).toBe(true);

    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", stopReason: "cancelled" } });
    daemon.touch(id, { status: "ready" });
    await until(() => !view.shown.isWorking);
    expect(view.shown.stopping).toBeUndefined();

    // The next turn starts fresh: no Stop is pending for it.
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    expect(view.shown.stopping).toBeUndefined();
  } finally {
    client.close?.();
  }
});
