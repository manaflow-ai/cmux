// A chat's first frame waits on one daemon round trip after the handshake, not one per read (Leo,
// 2026-10-29: "as in i want ours to load fast too :("). The open used to ask, one after another,
// `_acpmux/status`, the chat list, the attach, and then the turn opener, permissions and handoff:
// five waits on a busy daemon before the first row. These tests hold every reply until the test
// answers the requests out as one wave, and count the waves before the first frame with rows.
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
  send: (raw: string) => void;
};
type Sent = { method: string; wave: number; params?: Record<string, unknown> };

const turns = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/// Opens `mockHost`'s chat on `socket` with every reply held, answering what is out one wave at a
/// time. Answers the waves the first frame with rows waited on, and every request with its wave.
async function openCountingWaves(
  socket: unknown,
  rewrite: (method: string, reply: Record<string, unknown>) => void = () => {},
): Promise<{ waves: number; sent: Sent[]; close: () => void }> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { mockHost } = await import("./mock");
  // The mock opened before the page asked (`open`, below): the page is told so once it listens.
  await turns();
  const daemon = socket as Daemon & {
    onmessage: ((message: { data: string }) => void) | null;
    onopen: (() => void) | null;
  };
  const answer = daemon.send.bind(socket);
  const held: string[] = [];
  const sent: Sent[] = [];
  const methods = new Map<number, string>();
  let wave = 0;
  // Wakes the waves loop below when the page sends a request or paints rows.
  let wake = () => {};
  daemon.send = (raw) => {
    const request = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    if (request.id === undefined) return answer(raw);
    methods.set(request.id, request.method);
    sent.push({ method: request.method, wave, params: request.params });
    held.push(raw);
    wake();
  };
  let painted = false;
  const connecting = AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      const rows = (snapshot as { rows?: unknown[] }).rows;
      if (Array.isArray(rows) && rows.length > 0) {
        painted = true;
        wake();
      }
    },
    undefined,
    () => {
      // The page's own handler, with each reply rewritten as the test asks (an older daemon).
      queueMicrotask(() => {
        daemon.onopen?.();
        const page = daemon.onmessage;
        daemon.onmessage = (message) => {
          const parsed = JSON.parse(message.data) as { id?: number; result?: Record<string, unknown> };
          const method = parsed.id === undefined ? undefined : methods.get(parsed.id);
          if (method && parsed.result && typeof parsed.result === "object") {
            rewrite(method, parsed.result);
            page?.({ data: JSON.stringify(parsed) });
          } else page?.(message);
        };
      });
      return socket as WebSocket;
    },
  );
  // The host's tail read (none outside the app) and the socket's open settle with no reply out.
  while (!painted && wave < 12) {
    for (let i = 0; i < 20; i += 1) await turns();
    if (painted) break;
    if (held.length === 0) {
      // Nothing out: what the page waits on is not the daemon (at most the host's 250 ms race), so
      // no wave is counted until its next request or its first frame.
      await new Promise<void>((resolve) => {
        wake = resolve;
      });
      continue;
    }
    wave += 1;
    for (const raw of held.splice(0)) answer(raw);
  }
  // Everything after the first frame answers at once, so the open completes.
  daemon.send = answer;
  for (const raw of held.splice(0)) answer(raw);
  const client = await connecting;
  expect(painted).toBe(true);
  return { waves: wave, sent, close: () => client.close() };
}

test("a chat's first frame waits on the handshake and one round trip", async () => {
  const { MockAcpmuxSocket } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const { waves, sent, close } = await openCountingWaves(socket);
  try {
    const before = sent.filter((request) => request.wave < waves).map((request) => `${request.wave} ${request.method}`);
    // Wave 0: initialize alone (the app's bridge sends the person proof right after it). Wave 1:
    // the machines, the list, the attach and the chat's own reads, side by side.
    expect(waves).toBeLessThanOrEqual(2);
    expect(before[0]).toBe("0 initialize");
    const second = sent.filter((request) => request.wave === 1).map((request) => request.method);
    expect(second).toEqual(expect.arrayContaining(["_acpmux/status", "_acpmux/watch", "_acpmux/attach"]));
  } finally {
    close();
  }
});

/// A chat whose newest page starts inside a long turn: its prompt, then more records than a page holds.
function longTurn(socket: unknown, id: string): void {
  const daemon = socket as Daemon;
  daemon.emit(id, { mux: "user_message", msg: { text: "Port the parser", promptId: "p-long" } });
  for (let index = 0; index < 450; index += 1)
    daemon.emit(id, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `step ${index} ` } },
    });
}

test("the turn's opener comes with the attach page, not a read after it", async () => {
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  // Logged before any page listens, so no page hears it live.
  await turns();
  longTurn(socket, mockHost.sessionId!);
  const { waves, sent, close } = await openCountingWaves(socket);
  try {
    expect(waves).toBeLessThanOrEqual(2);
    // No `_acpmux/events` read of the turn's prompts: the attach named it.
    // (The rail's one prompt index read, direct.ts readPromptIndex, is not a read of the opener.)
    expect(
      sent.filter((request) => request.method === "_acpmux/events" && request.params?.promptIndex !== true),
    ).toEqual([]);
  } finally {
    close();
  }
});

test("an acpmux that does not name the opener still has it read", async () => {
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  // Logged before any page listens, so no page hears it live.
  await turns();
  longTurn(socket, mockHost.sessionId!);
  const { sent, close } = await openCountingWaves(socket, (method, reply) => {
    if (method === "_acpmux/attach") delete reply.turnOpener;
  });
  try {
    const reads = sent.filter((request) => request.method === "_acpmux/events" && request.params?.promptIndex !== true);
    expect(reads.length).toBe(1);
    expect(reads[0]!.params).toMatchObject({ kinds: ["user_message"], limit: 16 });
  } finally {
    close();
  }
});
