// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// How long a chat's finished turns take to show, and whether they ever go blank, when acpmux and
// the app host are slow to answer (Leo, 2026-11-10: "It's because we're at 100% CPU, but even if
// we're at that, we shouldn't need to resort to this kind of thing where the past literally is not
// visible"). The daemon answers every request `DAEMON_MS` late and the host every call `HOST_MS`
// late, as on a machine at load 100-260. Three opens of the same chat of finished turns:
//
// - reopen: the chat read in one tab, that tab closed, the chat opened in a new tab (a new page);
// - reconnect: the socket to acpmux drops under a chat on screen, and the pane connects again;
// - cold: a chat nothing in the app has read yet (the control: it waits on acpmux either way).
//
// Each prints its time to the first frame with rows and the frames it drew with none
// (`SETTLED_FIRST_PAINT` lines), and holds the first two to the settled-pages promise: the past is
// on screen before the daemon answers anything, and a reconnect never draws it blank.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";

setDefaultTimeout(60_000);
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

const DAEMON_MS = Number(process.env.SETTLED_DAEMON_MS ?? 400);
const HOST_MS = Number(process.env.SETTLED_HOST_MS ?? 300);
const TURNS = Number(process.env.SETTLED_TURNS ?? 30);
/// What "before the daemon answers" means: well under one daemon reply.
const BEFORE_DAEMON_MS = DAEMON_MS / 2;

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  send: (raw: string) => void;
  onopen: (() => void) | null;
  onclose: ((event?: { code?: number }) => void) | null;
  onmessage: ((message: { data: string }) => void) | null;
};
type Snapshot = { sessionId?: string; rows?: unknown[] };

const turns = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/// The app host, as tailCache.ts reaches it: in memory, answering `HOST_MS` late.
const hostTails = new Map<string, unknown>();
function installHost(): void {
  // fixed-wait: the host's latency under load is what this harness measures against.
  const late = <T>(value: T) => new Promise<T>((resolve) => setTimeout(() => resolve(value), HOST_MS));
  (dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }).cmuxAcpmuxActions = {
    "chat.tail": (params) => {
      if (params.tail) hostTails.set(params.sessionId, params.tail);
      else hostTails.delete(params.sessionId);
      return late(undefined);
    },
    "chat.tail.get": (params) => late(hostTails.get(params.sessionId) ?? null),
    "chat.snapshot.put": () => late(undefined),
  };
}

/// A mock daemon holding `TURNS` finished turns of the mock chat, answering `DAEMON_MS` late.
async function slowDaemon(): Promise<Daemon> {
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve()) as unknown as Daemon;
  await turns();
  const id = mockHost.sessionId!;
  for (let n = 0; n < TURNS; n += 1) {
    socket.emit(id, { mux: "user_message", msg: { text: `Question ${n}`, promptId: `p-${n}` } });
    socket.emit(id, { mux: "turn_started", msg: {} });
    socket.emit(id, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${n}, settled.` } },
    });
    socket.emit(id, { mux: "turn_result", msg: { status: "completed" } });
  }
  const answer = socket.send.bind(socket);
  socket.send = (raw) => {
    setTimeout(() => answer(raw), DAEMON_MS);
  };
  return socket;
}

type Open = {
  client: Promise<{ close(): void }>;
  firstRowsMs: Promise<number>;
  blankFrames: () => number;
  daemon: Daemon;
};

async function open(onLost?: () => void, since = performance.now()): Promise<Open> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { mockHost } = await import("./mock");
  const daemon = await slowDaemon();
  let blank = 0;
  let painted: (ms: number) => void = () => {};
  const firstRowsMs = new Promise<number>((resolve) => (painted = resolve));
  let done = false;
  const client = AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      const rows = (snapshot as Snapshot).rows ?? [];
      if (rows.length === 0) {
        if (!done) blank += 1;
        return;
      }
      if (!done) {
        done = true;
        painted(performance.now() - since);
      }
    },
    onLost,
    () => {
      // The socket opens after the page asked, as a real one does.
      queueMicrotask(() => daemon.onopen?.());
      return daemon as unknown as WebSocket;
    },
  );
  return { client, firstRowsMs, blankFrames: () => blank, daemon };
}

async function settledModule(): Promise<
  { resetSettledForTests(shared?: Map<string, unknown[]>): void } | undefined
> {
  try {
    // @ts-ignore: absent before the settled pages (the same harness measures both trees).
    return (await import("./settledPages")) as never;
  } catch {
    return undefined;
  }
}

function report(scenario: string, firstRowsMs: number, blankFrames: number): void {
  console.log(
    `SETTLED_FIRST_PAINT scenario=${scenario} first_rows_ms=${firstRowsMs.toFixed(1)} blank_frames=${blankFrames} daemon_ms=${DAEMON_MS} host_ms=${HOST_MS} turns=${TURNS}`,
  );
}

test("reopen: a chat read in a closed tab shows its finished turns in a new tab before acpmux answers", async () => {
  const { resetKeptTailsForTests } = await import("./tailCache");
  const settled = await settledModule();
  const shared = new Map<string, unknown[]>();
  resetKeptTailsForTests();
  settled?.resetSettledForTests(shared);
  hostTails.clear();
  installHost();
  // The first tab reads the chat and closes.
  const first = await open();
  const firstClient = await first.client;
  await first.firstRowsMs;
  firstClient.close();
  // fixed-wait: the closed tab's hand-over to the slow host lands before the next tab opens.
  await new Promise((resolve) => setTimeout(resolve, HOST_MS + 50));
  // A new tab: a new page (no tails, no pages in memory), the same app (host, shared store).
  resetKeptTailsForTests();
  settled?.resetSettledForTests(shared);
  const second = await open();
  const ms = await second.firstRowsMs;
  report("reopen", ms, second.blankFrames());
  (await second.client).close();
  if (settled) expect(ms).toBeLessThan(BEFORE_DAEMON_MS);
});

test("reconnect: a dropped socket never blanks the finished turns on screen", async () => {
  const { resetKeptTailsForTests } = await import("./tailCache");
  const settled = await settledModule();
  resetKeptTailsForTests();
  settled?.resetSettledForTests(new Map());
  hostTails.clear();
  installHost();
  let lost: () => void = () => {};
  const lostOnce = new Promise<void>((resolve) => (lost = resolve));
  const first = await open(() => lost());
  await first.client;
  await first.firstRowsMs;
  // The socket drops (acpmux restarted, or a stalled socket closed under load).
  const droppedAt = performance.now();
  first.daemon.onclose?.({ code: 1006 });
  await lostOnce;
  // The pane asks the host again (App.tsx `connectHost`: `ready`), then connects a new client.
  // fixed-wait: the pane's `ready` round trip to the slow host, as App.tsx makes it.
  await new Promise((resolve) => setTimeout(resolve, HOST_MS));
  const again = await open(undefined, droppedAt);
  const ms = await again.firstRowsMs;
  report("reconnect", ms, again.blankFrames());
  (await again.client).close();
  expect(again.blankFrames()).toBe(0);
  if (settled) expect(ms).toBeLessThan(HOST_MS + BEFORE_DAEMON_MS);
});

test("cold: a chat nothing has read waits on acpmux (control)", async () => {
  const { resetKeptTailsForTests } = await import("./tailCache");
  const settled = await settledModule();
  resetKeptTailsForTests();
  settled?.resetSettledForTests(new Map());
  hostTails.clear();
  installHost();
  const cold = await open();
  const ms = await cold.firstRowsMs;
  report("cold", ms, cold.blankFrames());
  (await cold.client).close();
  expect(ms).toBeGreaterThan(0);
});
