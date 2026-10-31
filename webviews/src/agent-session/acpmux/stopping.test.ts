// Stop and Esc are seen to take (Leo, 2026-10-21: "ALSO THE ESC THING IDK IF IM ACTUALLY STOPPING
// YOU WITH THESE"): from the Stop until the turn ends, the snapshot says it is stopping, and the
// turn's end takes that away.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
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
    daemon.emit(id, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "stop-opener-before-rebuild" } },
    });
    await until(() => said("stop-opener-before-rebuild"));
    expect(view.shown.isWorking).toBe(true);
    expect(view.shown.stopping).toBe(true);
    // A rebuild (reconnect, older history, lag resync) replays that same opener: still the stopped turn.
    (client as unknown as { rebuild(): void }).rebuild();
    daemon.touch(id, { status: "running" });
    daemon.emit(id, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "stop-opener-after-rebuild" } },
    });
    await until(() => said("stop-opener-after-rebuild"));
    expect(view.shown.isWorking).toBe(true);
    expect(view.shown.stopping).toBe(true);
    daemon.emit(id, { mux: "turn_end", msg: { stopReason: "cancelled" } });
    await until(() => view.shown.stopping === undefined);
  } finally {
    client.close?.();
  }
});

// The cancel transport is a JSON-RPC notification, so its promise settles on send, not turn-end.
// Keep the daemon's turn open independently of that promise and drive each lifecycle explicitly.
async function withStoppingClient(run: (fixture: Awaited<ReturnType<typeof stoppingClient>>) => Promise<void>) {
  const fixture = await stoppingClient();
  try {
    await run(fixture);
  } finally {
    fixture.client.close();
    jest.useRealTimers();
  }
}

async function stoppingClient() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const sent: Array<{ id?: number; method: string; params: { sessionId: string } }> = [];
  const control = { fail: false, intercept: (_raw: string) => false };
  const send = socket.send.bind(socket);
  socket.send = (raw) => {
    const request = JSON.parse(raw);
    if (request.method === "session/cancel") {
      if (control.fail) throw new Error("cancel transport failed");
      sent.push(request);
    } else if (!control.intercept(raw)) send(raw);
  };
  let shown: import("./model").AcpmuxSnapshot;
  const wakes: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const id = mockHost.sessionId!;
  await until(() => shown?.summary !== undefined);
  let marker = 0;
  const flush = async (target = id) => {
    const text = `stop-lifecycle-barrier-${++marker}`;
    daemon.emit(target, { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });
    await until(() => shown.rows.some((row) => row.text?.includes(text)));
  };
  const start = async (turnId = "stop-turn-1", target = id) => {
    daemon.touch(target, { status: "running", turn: { turnId } });
    daemon.emit(target, { mux: "turn_started", msg: { turnId } });
    await flush(target);
  };
  const end = async (turnId = "stop-turn-1") => {
    daemon.emit(id, { mux: "turn_end", msg: { turnId, stopReason: "cancelled" } });
    daemon.emit(id, { mux: "turn_result", msg: { turnId, status: "cancelled" } });
    daemon.touch(id, { status: "idle", turn: undefined });
    await until(() => !shown.isWorking);
  };
  return { client, socket, daemon, id, sent, control, send, until, flush, start, end, shown: () => shown };
}

test("cancel resolution and the old grace deadline do not end Stopping", () =>
  withStoppingClient(async (f) => {
    await f.start();
    const notices = f.shown().rows.filter((row) => row.kind === "notice").length;
    jest.useFakeTimers();
    await f.client.cancel();
    expect(f.sent[0]?.id).toBeUndefined();
    expect(f.shown().stopping).toBe(true);
    // Older clients hid the turn after five seconds, before the daemon's forced end.
    jest.advanceTimersByTime(6_000);
    expect(f.shown().isWorking).toBe(true);
    expect(f.shown().stopping).toBe(true);
    expect(f.shown().rows.filter((row) => row.kind === "notice")).toHaveLength(notices);
    jest.useRealTimers();
    await f.end();
    expect(f.shown().stopping).toBeUndefined();
    await f.start("stop-turn-2");
    expect(f.shown().stopping).toBeUndefined();
  }));

test("a failed cancel send leaves Stop available for a successful retry", () =>
  withStoppingClient(async (f) => {
    await f.start();
    f.control.fail = true;
    await expect(f.client.cancel()).rejects.toThrow("cancel transport failed");
    expect(f.shown().stopping).toBeUndefined();
    expect(f.shown().isWorking).toBe(true);
    f.control.fail = false;
    await f.client.cancel();
    expect(f.shown().stopping).toBe(true);
    await f.end();
    await f.start("stop-turn-2");
    expect(f.shown().stopping).toBeUndefined();
  }));

test("a closing socket rejects Stop without creating a pending stop", () =>
  withStoppingClient(async (f) => {
    await f.start();
    f.socket.readyState = WebSocket.CLOSING;
    await expect(f.client.cancel()).rejects.toMatchObject({ code: "native.not_connected" });
    expect(f.sent).toHaveLength(0);
    expect(f.shown().stopping).toBeUndefined();
  }));

test("disconnect clears Stopping and cannot leave a later turn stopping", () =>
  withStoppingClient(async (f) => {
    await f.start();
    await f.client.cancel();
    expect(f.shown().stopping).toBe(true);
    jest.useFakeTimers();
    f.socket.readyState = WebSocket.CLOSED;
    f.socket.onclose?.();
    expect(f.shown().connection).toBe("disconnected");
    expect(f.shown().stopping).toBeUndefined();
    // Resume deliveries before the reconnect timer runs, then simulate the daemon's next turn.
    f.socket.readyState = WebSocket.OPEN;
    jest.useRealTimers();
    await f.start("stop-turn-2");
    expect(f.shown().isWorking).toBe(true);
    expect(f.shown().stopping).toBeUndefined();
  }));

test("a different turn id clears Stop even if its predecessor's end was missed", () =>
  withStoppingClient(async (f) => {
    await f.start();
    await f.client.cancel();
    // A late opener for the stopped turn is not a new turn.
    await f.start();
    expect(f.shown().stopping).toBe(true);
    await f.start("stop-turn-2");
    expect(f.shown().isWorking).toBe(true);
    expect(f.shown().stopping).toBeUndefined();
  }));

test("Stop during a held session switch targets the drawn chat and leaves the new one fresh", () =>
  withStoppingClient(async (f) => {
    await f.start();
    await f.client.cancel();
    const other = f.shown().sessions.find((session) => session.sessionId !== f.id)!.sessionId;
    const { forgetTail } = await import("./tailCache");
    forgetTail(other);
    let held = "";
    let attached = () => {};
    const attaching = new Promise<void>((resolve) => (attached = resolve));
    f.control.intercept = (raw) => {
      const request = JSON.parse(raw);
      if (request.method !== "_acpmux/attach" || request.params.sessionId !== other) return false;
      held = raw;
      attached();
      return true;
    };
    const selected = f.client.select(other);
    await attaching;
    expect(f.shown().sessionId).toBe(f.id);
    await f.client.cancel();
    expect(f.sent.map((request) => request.params.sessionId)).toEqual([f.id, f.id]);
    f.send(held);
    await selected;
    expect(f.shown().sessionId).toBe(other);
    expect(f.shown().stopping).toBeUndefined();
    await f.start("other-turn", other);
    // Cancel has no request id: an unmatched late result or error cannot settle the new turn.
    for (const reply of [{ result: {} }, { error: { code: -32000, message: "old cancel failed" } }]) {
      f.socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: 999999, ...reply }) });
    }
    await f.flush(other);
    expect(f.shown().isWorking).toBe(true);
    expect(f.shown().stopping).toBeUndefined();
    await f.client.cancel();
    expect(f.shown().stopping).toBe(true);
    expect(f.sent.at(-1)?.params.sessionId).toBe(other);
  }));
