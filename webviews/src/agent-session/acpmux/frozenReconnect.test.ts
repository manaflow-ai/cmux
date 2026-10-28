// The host closes a frozen idle chat's acpmux connection and hands that close to the
// page at the thaw, after the frames that arrived before it (Swift AgentPaneTransport.closeWhileFrozen).
// The page opens again on the same client and resumes after the last event it has: the transcript
// shows what the chat recorded while it was frozen, with no missing row, no empty-transcript frame,
// no "disconnected" frame, and no fresh handshake through the pane's daemon-loss path (onLost).
// The real client and bridge socket against one mock daemon behind a stand-in host.
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

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 2000 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Snapshot = { connection: string; sessionId?: string; rows: { kind: string; text?: string }[] };
type Daemon = { emit(target: string, step: unknown): void };

test("a freeze close reopens on the same client and shows what the frozen chat recorded, with no gap", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { BridgeSocket, PAGE_FROZEN_CLOSE_REASON, receiveTransportEvent } = await import("./bridgeSocket");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");

  // One daemon behind the host, which owns the connections as AgentPaneTransport does.
  const daemon = new MockAcpmuxSocket(() => Promise.resolve());
  let current: number | undefined;
  let opened = 0;
  // Frames that arrive while the page is frozen wait in the host (the frozen pacer).
  let held: string[] | undefined;
  daemon.onmessage = ({ data }) => {
    // A closed connection gets nothing: acpmux sends a frozen chat no frame.
    if (current === undefined) return;
    if (held) held.push(data);
    else receiveTransportEvent({ connection: current, frames: [data] });
  };
  const post = async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    if (method === "transport.open") {
      opened += 1;
      current = opened;
      return { connection: current } as T;
    }
    if (method === "transport.send") {
      for (const frame of (params?.frames ?? []) as string[]) daemon.send(frame);
      return undefined as T;
    }
    if (method === "transport.close") {
      if (params?.connection === current) current = undefined;
      return undefined as T;
    }
    throw new Error(`unexpected ${method}`);
  };

  const snapshots: Snapshot[] = [];
  let lost = 0;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => snapshots.push(next as unknown as Snapshot),
    () => (lost += 1),
    () => new BridgeSocket(post) as unknown as WebSocket,
  );
  try {
    const session = daemon.seedLoadSession(3);
    await client.select(session);
    const prompts = (snapshot?: Snapshot) =>
      (snapshot?.rows ?? []).filter((row) => row.kind === "user").map((row) => row.text ?? "");
    const latest = () => prompts(snapshots.at(-1));
    const turn = (text: string) => {
      const emit = (daemon as unknown as Daemon).emit.bind(daemon);
      emit(session, { mux: "user_message", msg: { text } });
      emit(session, { mux: "turn_started" });
      emit(session, { mux: "turn_result", msg: { status: "completed" } });
    };

    turn("Live 1");
    await settle(() => latest().includes("Live 1"));
    expect(latest()).toHaveLength(4);
    const shownBefore = latest();

    // Frozen: a turn arrives and waits in the host, then the host closes the connection, and acpmux
    // records two more turns that no connection gets.
    held = [];
    turn("Frozen 1");
    await settle(() => held!.length >= 3);
    const frozenConnection = current!;
    current = undefined;
    turn("Frozen 2");
    turn("Frozen 3");
    await new Promise((resolve) => setTimeout(resolve, 0));

    // The thaw: what waited, then the freeze close, in one push.
    const thawAt = snapshots.length;
    const frames = held;
    held = undefined;
    receiveTransportEvent({
      connection: frozenConnection,
      frames,
      closed: { code: 1000, reason: PAGE_FROZEN_CLOSE_REASON },
    });
    await settle(() => latest().includes("Frozen 3"));

    expect(latest()).toEqual([...shownBefore, "Frozen 1", "Frozen 2", "Frozen 3"]);
    expect(opened).toBe(2);
    // The host opened the second connection (TypeScript narrowed `current` when the test cleared it).
    expect(current as number | undefined).toBe(2);
    expect(lost).toBe(0);
    const afterThaw = snapshots.slice(thawAt);
    expect(afterThaw.filter((snapshot) => snapshot.connection === "disconnected")).toEqual([]);
    for (const snapshot of afterThaw) {
      expect(snapshot.sessionId).toBe(session);
      // Every frame keeps every row shown before the freeze, in order.
      expect(prompts(snapshot).slice(0, shownBefore.length)).toEqual(shownBefore);
    }

    // A close with no freeze reason is a lost daemon still: the pane says so and asks for a handshake.
    const lossAt = snapshots.length;
    receiveTransportEvent({ connection: current!, closed: { code: 1006, reason: "" } });
    await settle(() => lost === 1);
    expect(lost).toBe(1);
    expect(snapshots.slice(lossAt).some((snapshot) => snapshot.connection === "disconnected")).toBe(true);
  } finally {
    client.close();
  }
});
