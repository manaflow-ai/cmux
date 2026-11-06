// After acpmux restarts, the pane's socket can stay open while nothing behind it answers. The pane
// waited for its requests, said "Waiting for the agent service (m:ss)" and gave the socket up only
// after two minutes without a frame, though the new daemon was up long before (ask-34b8c4ef25).
// A daemon that is only slow still answers a probe, and its socket is kept.
import { afterEach, expect, jest, test } from "bun:test";

/// A socket to the mock daemon that can go silent: from `silence()` on, nothing the page sends
/// reaches the daemon and nothing comes back, while the socket stays open, as when the acpmux
/// behind the app's bridge is gone. `holds` names methods the daemon receives and never answers
/// (a slow daemon's long read); every other method is answered as before.
class SilenceableSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  silent = false;
  sent: string[] = [];
  constructor(
    private readonly daemon: {
      readyState: number;
      onopen: (() => void) | null;
      onmessage: ((message: { data: string }) => void) | null;
      send(raw: string): void;
    },
    private readonly holds: Set<string>,
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
  send(raw: string): void {
    this.sent.push(raw);
    if (this.silent) return;
    const method = (JSON.parse(raw) as { method?: string }).method;
    if (method && this.holds.has(method)) return;
    this.daemon.send(raw);
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
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new SilenceableSocket(new MockAcpmuxSocket(() => Promise.resolve()), new Set(holds));
  let lost = 0;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    () => {
      lost += 1;
    },
    () => socket as unknown as WebSocket,
  );
  const request = (
    client as unknown as {
      request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
    }
  ).request.bind(client);
  return { client, socket, request, lost: () => lost, mockHost };
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
