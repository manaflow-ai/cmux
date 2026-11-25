// A live daemon can still lose one request: its frame never reached the daemon, or its reply never
// left. The socket's liveness proved the daemon, never the request, so session/new, set_model, a
// fork or a chat open waited for good behind a "Creating" spinner (Leo, 2026-11-24: "I feel like
// there are often these like dead hang loops"). The pane now asks the daemon which of its requests
// it still runs (`_acpmux/request_state`): a running one is kept however slow; one the daemon
// neither runs nor answered gives the socket up, and the reconnect recovers it.
import { afterEach, expect, jest, test } from "bun:test";
// Loaded before the file starts, as the app loads it (selfHeal.test.tsx): its global hook is no leak.
import "./computerUse/computerUseState";

type Frame = { id?: number; method?: string };

/// A socket to the mock daemon. `drops` names methods whose frames never reach the daemon (lost on
/// the way); `holds` names ones the daemon reads and runs without answering yet (a slow request).
/// Like acpmux `server/in_flight.rs`, it answers `_acpmux/request_state` with the held ids as
/// running. `relay` adds the app relay's `relayed` list (only those it wrote; `hostHolds` it keeps
/// back, a confirmation sheet); `old` answers the question as an older daemon: method not found.
class StateSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: string[] = [];
  running = new Set<number>();
  written = new Set<number>();
  constructor(
    private readonly daemon: {
      onopen: (() => void) | null;
      onmessage: ((message: { data: string }) => void) | null;
      send(raw: string): void;
    },
    private readonly options: {
      drops?: string[];
      holds?: string[];
      hostHolds?: string[];
      relay?: boolean;
      old?: boolean;
    },
  ) {
    daemon.onopen = () => {
      this.readyState = 1;
      this.onopen?.();
    };
    daemon.onmessage = (message) => {
      if (this.readyState === 1) this.onmessage?.(message);
    };
  }
  questions(): number {
    return this.sent.filter((raw) => (JSON.parse(raw) as Frame).method === "_acpmux/request_state").length;
  }
  send(raw: string): void {
    this.sent.push(raw);
    const { id, method } = JSON.parse(raw) as Frame;
    if (method === "_acpmux/request_state") {
      if (this.options.old) {
        return this.reply({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } });
      }
      const result: Record<string, number[]> = { running: [...this.running], answered: [] };
      if (this.options.relay) result.relayed = [...this.written];
      return this.reply({ jsonrpc: "2.0", id, result });
    }
    if (method && this.options.hostHolds?.includes(method)) return;
    if (typeof id === "number") this.written.add(id);
    if (method && this.options.drops?.includes(method)) return;
    if (method && this.options.holds?.includes(method) && typeof id === "number") {
      this.running.add(id);
      return;
    }
    this.daemon.send(raw);
  }
  private reply(frame: unknown): void {
    queueMicrotask(() => {
      if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify(frame) });
    });
  }
  close(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    queueMicrotask(() => this.onclose?.({ code: 1000, reason: "", wasClean: true }));
  }
}

afterEach(() => {
  jest.useRealTimers();
});

async function connected(options: ConstructorParameters<typeof StateSocket>[1]) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new StateSocket(new MockAcpmuxSocket(() => Promise.resolve()), options);
  let lost = 0;
  // Fake from the handshake on: the pane's checks are timed from its first requests.
  jest.useFakeTimers();
  const opening = AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    () => {
      lost += 1;
    },
    () => socket as unknown as WebSocket,
  );
  let client: Awaited<typeof opening> | undefined;
  void opening.then((opened) => (client = opened));
  for (let step = 0; step < 200 && !client; step++) {
    jest.advanceTimersByTime(10);
    await settle();
  }
  if (!client) throw new Error("the handshake did not finish");
  const request = (
    client as unknown as { request(method: string, params: Record<string, unknown>): Promise<unknown> }
  ).request.bind(client);
  return { client, socket, request, lost: () => lost, mockHost };
}

async function settle(): Promise<void> {
  for (let index = 0; index < 20; index++) await Promise.resolve();
}

/// Runs `seconds` of fake time a second at a time, stopping once the pane gave its socket up.
async function run(seconds: number, lost: () => number): Promise<number> {
  for (let second = 1; second <= seconds; second++) {
    jest.advanceTimersByTime(1_000);
    await settle();
    if (lost() > 0) return second;
  }
  return seconds;
}

for (const method of ["session/new", "session/set_model"]) {
  test(`a ${method} the daemon never read is given up within 30 s, so the reconnect recovers it`, async () => {
    const { client, socket, request, lost, mockHost } = await connected({ drops: [method] });
    try {
      const asked = request(method, { cwd: "/tmp", sessionId: mockHost.sessionId, modelId: "m" });
      asked.catch(() => undefined);
      // Before: no reply ever came, and the request waited for good on a live socket (the run
      // ended at 600 s with nothing lost). After: two answers in a row without it.
      const seconds = await run(600, lost);
      expect(lost()).toBe(1);
      expect(seconds).toBeLessThanOrEqual(30);
      expect(socket.questions()).toBe(2);
      await expect(asked).rejects.toMatchObject({ interrupted: true });
    } finally {
      client.close();
    }
  });
}

test("a slow request the daemon still runs keeps its socket for ten minutes", async () => {
  const { client, socket, request, lost, mockHost } = await connected({ holds: ["_acpmux/events"] });
  try {
    let settled = false;
    const read = request("_acpmux/events", { sessionId: mockHost.sessionId, afterSeq: 0, limit: 1 });
    read.then(
      () => (settled = true),
      () => (settled = true),
    );
    await run(600, lost);
    // Slow is never lost: the daemon said it runs the read each time it was asked.
    expect(lost()).toBe(0);
    expect(settled).toBe(false);
    expect(socket.readyState).toBe(1);
    // One cheap question every 10 s while the request runs, never more.
    expect(socket.questions()).toBeLessThanOrEqual(60);
  } finally {
    client.close();
  }
});

test("a request the app's host still holds (a confirmation sheet) is never judged lost", async () => {
  const { client, socket, request, lost, mockHost } = await connected({ relay: true, hostHolds: ["session/new"] });
  try {
    const asked = request("session/new", { cwd: "/tmp", sessionId: mockHost.sessionId });
    asked.catch(() => undefined);
    await run(120, lost);
    expect(lost()).toBe(0);
    expect(socket.readyState).toBe(1);
    expect(socket.questions()).toBeGreaterThan(0);
  } finally {
    client.close();
  }
});

test("an older daemon that does not know the question is asked once, and nothing is given up", async () => {
  const { client, socket, request, lost, mockHost } = await connected({ old: true, drops: ["session/new"] });
  try {
    const asked = request("session/new", { cwd: "/tmp", sessionId: mockHost.sessionId });
    asked.catch(() => undefined);
    await run(120, lost);
    expect(lost()).toBe(0);
    expect(socket.questions()).toBe(1);
  } finally {
    client.close();
  }
});

test("a fast request costs no question", async () => {
  const { client, socket, request, lost } = await connected({});
  try {
    await request("_acpmux/peers", {});
    await run(60, lost);
    expect(socket.questions()).toBe(0);
  } finally {
    client.close();
  }
});
