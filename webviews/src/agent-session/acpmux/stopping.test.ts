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

type Shown = { isWorking: boolean; stopping?: true; summary?: unknown; rows?: unknown };

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

    // The turn's end takes it away, while acpmux still lists the chat as running.
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled" } });
    await until(() => view.shown.stopping === undefined);
    expect(view.shown.isWorking).toBe(true);
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", stopReason: "cancelled" } });
    daemon.touch(id, { status: "ready" });
    await until(() => !view.shown.isWorking);
    expect(view.shown.stopping).toBeUndefined();

    // The next turn starts fresh: no Stop is pending for it.
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { mux: "turn_started" });
    await until(() => view.shown.isWorking);
    expect(view.shown.stopping).toBeUndefined();
    daemon.emit(id, { mux: "turn_result", msg: { status: "completed", stopReason: "end_turn" } });
    daemon.touch(id, { status: "ready" });
    await until(() => !view.shown.isWorking);
  } finally {
    client.close?.();
  }
});

test("a Stop sent before its turn opens here keeps saying it is stopping through that opening", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const send = daemon.send.bind(socket);
  daemon.send = (raw) => {
    if ((JSON.parse(raw) as { method?: string }).method !== "session/cancel") send(raw);
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
    // acpmux lists the chat running before its prompt (which opens the turn here) and the agent's
    // turn_started arrive: a Stop then is for the turn those open.
    daemon.touch(id, { status: "running" });
    await until(() => view.shown.isWorking);
    await client.cancel();
    await until(() => view.shown.stopping === true);
    daemon.emit(id, { mux: "user_message", msg: { text: "go" } });
    daemon.emit(id, { mux: "turn_started" });
    // The agent's first words come after the opener: once they show, the opener has been read.
    const said = (words: string) => JSON.stringify(view.shown.rows ?? []).includes(words);
    daemon.emit(id, { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "first" } } });
    await until(() => said("first"));
    expect(view.shown.isWorking).toBe(true);
    expect(view.shown.stopping).toBe(true);
    // A rebuild (reconnect, older history, lag resync) replays that same opener: still the stopped turn.
    (client as unknown as { rebuild(): void }).rebuild();
    daemon.touch(id, { status: "running" });
    daemon.emit(id, { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "second" } } });
    await until(() => said("second"));
    expect(view.shown.isWorking).toBe(true);
    expect(view.shown.stopping).toBe(true);
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled" } });
    await until(() => view.shown.stopping === undefined);
  } finally {
    client.close?.();
  }
});
