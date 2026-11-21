// After acpmux restarts, the pane's socket can stay open while nothing behind it answers. The pane
// waited for its requests, said "Waiting for the agent service (m:ss)" and gave the socket up only
// after two minutes without a frame, though the new daemon was up long before (ask-34b8c4ef25).
// A daemon that is only slow still answers a probe, and its socket is kept.
import { afterEach, expect, jest, test } from "bun:test";

/// A socket to the mock daemon that can go silent: from `silence()` on, nothing the page sends
/// reaches the daemon and nothing comes back, while the socket stays open, as when the acpmux
/// behind the app's bridge is gone. `holds` names methods the daemon receives and never answers
/// (a slow daemon's long read); every other method is answered as before. Like the app's bridge
/// (`AgentPaneTransport+Check.swift`), it answers `_acpmux/status` itself, from the daemon's Unix
/// socket: with no daemon, a "status unavailable" error frame still comes back. The mock daemon
/// has no machines, so `_acpmux/peers` gets an empty list from it. A `remote` socket stands for a
/// chat on another machine (`RemoteAcpmuxWire`): it refuses `_acpmux/peers` itself as
/// `remote.unsupported`, with no daemon involved. `release()` lets the held frames reach the daemon.
class SilenceableSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  silent = false;
  sent: string[] = [];
  private held: string[] = [];
  constructor(
    private readonly daemon: {
      readyState: number;
      onopen: (() => void) | null;
      onmessage: ((message: { data: string }) => void) | null;
      send(raw: string): void;
    },
    private readonly holds: Set<string>,
    private readonly remote = false,
  ) {
    daemon.onopen = () => {
      this.readyState = 1;
      this.onopen?.();
    };
    daemon.onmessage = (message) => {
      if (!this.silent && this.readyState === 1) this.onmessage?.(message);
    };
  }
  silence(): void {
    this.silent = true;
  }
  release(): void {
    for (const raw of this.held.splice(0)) this.daemon.send(raw);
  }
  send(raw: string): void {
    this.sent.push(raw);
    const { id, method } = JSON.parse(raw) as { id?: number; method?: string };
    if (method === "_acpmux/status" && this.silent) {
      const error = { code: -32000, message: "status unavailable" };
      return this.reply({ jsonrpc: "2.0", id, error });
    }
    if (method === "_acpmux/peers" && this.remote) {
      const message = "_acpmux/peers is not available for a chat on another machine";
      const error = { code: -32601, message, data: { code: "remote.unsupported" } };
      return this.reply({ jsonrpc: "2.0", id, error });
    }
    if (this.silent) return;
    if (method && this.holds.has(method)) {
      this.held.push(raw);
      return;
    }
    if (method === "_acpmux/peers") return this.reply({ jsonrpc: "2.0", id, result: { peers: [] } });
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

async function connected(holds: string[]) {
  const connection = await connecting(holds);
  const client = await connection.client;
  const request = (
    client as unknown as {
      request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
    }
  ).request.bind(client);
  return { ...connection, client, request };
}

async function connecting(holds: string[], remote = false) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new SilenceableSocket(new MockAcpmuxSocket(() => Promise.resolve()), new Set(holds), remote);
  let lost = 0;
  const client = AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    () => {
      lost += 1;
    },
    () => socket as unknown as WebSocket,
  );
  return { client, socket, lost: () => lost, mockHost };
}

/// Lets the microtasks a timer queued (the mock's replies, a close's onclose) run.
async function settle(): Promise<void> {
  for (let index = 0; index < 20; index++) await Promise.resolve();
}

test("a socket whose daemon went silent is given up within 20 s, so the pane asks for the new daemon", async () => {
  const { client, socket, request, lost, mockHost } = await connected([]);
  try {
    jest.useFakeTimers();
    socket.silence();
    // A read the pane asked after the daemon went away: it crosses its progress threshold and waits.
    const read = request("_acpmux/events", { sessionId: mockHost.sessionId, afterSeq: 0, limit: 1 }, 1_000);
    read.catch(() => undefined);
    for (let second = 0; second < 20 && lost() === 0; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    // The lost path ran: the host is asked for a fresh handshake, which finds the restarted daemon.
    // Before, the pane kept the dead socket for DAEMON_LIVENESS_GRACE_MS (two minutes) and counted
    // "Waiting for the agent service" meanwhile.
    expect(lost()).toBe(1);
    await expect(read).rejects.toMatchObject({ interrupted: true });
  } finally {
    client.close();
  }
});

test("a slow daemon that still answers keeps its socket and its long read", async () => {
  const { client, socket, request, lost, mockHost } = await connected(["_acpmux/events"]);
  try {
    jest.useFakeTimers();
    let settled = false;
    const read = request("_acpmux/events", { sessionId: mockHost.sessionId, afterSeq: 0, limit: 1 }, 1_000);
    read.then(
      () => (settled = true),
      () => (settled = true),
    );
    for (let second = 0; second < 60; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    // The daemon answered the pane's probe, so the long read is a slow one, never a lost socket.
    expect(lost()).toBe(0);
    expect(settled).toBe(false);
    expect(socket.readyState).toBe(1);
  } finally {
    client.close();
  }
});

test("a probe the app's bridge answers itself, with no daemon behind it, still ends the socket within 25 s", async () => {
  const { client, socket, request, lost, mockHost } = await connected([]);
  try {
    jest.useFakeTimers();
    socket.silence();
    // The pane's own status read, as its peers refresh sends: the bridge answers it with an error.
    void request("_acpmux/status", {}, 1_000).catch(() => undefined);
    const read = request("_acpmux/events", { sessionId: mockHost.sessionId, afterSeq: 0, limit: 1 }, 1_000);
    read.catch(() => undefined);
    for (let second = 0; second < 25 && lost() === 0; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    // Frames came back, but none from a daemon: the socket is given up all the same.
    expect(socket.sent.some((raw) => raw.includes('"_acpmux/status"'))).toBe(true);
    expect(lost()).toBe(1);
    await expect(read).rejects.toMatchObject({ interrupted: true });
  } finally {
    client.close();
  }
});

test("a chat on another machine whose handshake answers at 25 s is not cut off", async () => {
  jest.useFakeTimers();
  // The remote wire refuses the probe itself; that refusal says nothing of the daemon there.
  const { client, socket, lost } = await connecting(["initialize"], true);
  let connected: Awaited<typeof client> | undefined;
  let failed: unknown;
  client.then(
    (value) => (connected = value),
    (error: unknown) => (failed = error),
  );
  try {
    for (let second = 0; second < 25 && failed === undefined; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    expect(socket.sent.some((raw) => raw.includes('"_acpmux/peers"'))).toBe(true);
    expect(failed).toBeUndefined();
    expect(lost()).toBe(0);
    socket.release();
    for (let second = 0; second < 5 && connected === undefined && failed === undefined; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    expect(failed).toBeUndefined();
    expect(connected).toBeDefined();
    expect(socket.readyState).toBe(1);
  } finally {
    connected?.close();
  }
});

test("the bridge's own answers every 4 s do not put off the probe of a silent daemon", async () => {
  const { client, socket, request, lost, mockHost } = await connected([]);
  try {
    jest.useFakeTimers();
    socket.silence();
    const read = request("_acpmux/events", { sessionId: mockHost.sessionId, afterSeq: 0, limit: 1 }, 1_000);
    read.catch(() => undefined);
    for (let second = 0; second < 25 && lost() === 0; second++) {
      // The pane's peers refresh: the bridge answers each status read with an error frame.
      if (second % 4 === 0) void request("_acpmux/status", {}, 1_000).catch(() => undefined);
      jest.advanceTimersByTime(1_000);
      await settle();
    }
    expect(socket.sent.some((raw) => raw.includes('"_acpmux/peers"'))).toBe(true);
    expect(lost()).toBe(1);
    await expect(read).rejects.toMatchObject({ interrupted: true });
  } finally {
    client.close();
  }
});

// A chat switch after acpmux restarted: the pane sent its attach, detach and transcript reads with
// no deadline, so none of them ever counted as waiting and the probe above never ran. The click
// did nothing and the pane kept the dead socket until the app restarted (ask-fdfc5d8abb).
for (const method of ["_acpmux/attach", "_acpmux/detach", "_acpmux/events", "_acpmux/view", "_acpmux/watch"]) {
  test(`a chat switch's ${method} with no deadline of its own still gives up a silent daemon within 30 s`, async () => {
    const { client, socket, request, lost, mockHost } = await connected([]);
    try {
      jest.useFakeTimers();
      socket.silence();
      const asked = (request as (method: string, params: Record<string, unknown>) => Promise<unknown>)(method, {
        sessionId: mockHost.sessionId,
      });
      asked.catch(() => undefined);
      for (let second = 0; second < 30 && lost() === 0; second++) {
        jest.advanceTimersByTime(1_000);
        await settle();
      }
      expect(lost()).toBe(1);
      await expect(asked).rejects.toMatchObject({ interrupted: true });
    } finally {
      client.close();
    }
  });
}

test("a turn's session/prompt, which stays open while the agent works, never counts as waiting", async () => {
  const { client, socket, request, lost, mockHost } = await connected(["session/prompt"]);
  try {
    jest.useFakeTimers();
    let waited = false;
    const asked = (request as (method: string, params: Record<string, unknown>) => Promise<unknown>)("session/prompt", {
      sessionId: mockHost.sessionId,
      prompt: [{ type: "text", text: "hi" }],
    });
    asked.catch(() => undefined);
    for (let second = 0; second < 60; second++) {
      jest.advanceTimersByTime(1_000);
      await settle();
      if ((client as unknown as { daemonWaitingSince?: number }).daemonWaitingSince !== undefined) waited = true;
    }
    expect(waited).toBe(false);
    expect(lost()).toBe(0);
    expect(socket.readyState).toBe(1);
  } finally {
    client.close();
  }
});
