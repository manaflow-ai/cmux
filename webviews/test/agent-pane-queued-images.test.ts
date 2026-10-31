// l10n-allow-file: test fixture prompts, not shipped UI.
// A queued prompt keeps its images in the pane's queue (Leo, 2026-10-21: "do queued messages have
// pics?"; acpmux kept and sent the screenshot, the row showed only text). acpmux names them on the
// session's queue (`images: [{id, mimeType, name}]`, after a reload or a daemon restart) and on its
// `queued` and `queue_updated` records; a prompt sent behind the running turn shows its own images
// at once, before acpmux answers.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { QueuedPrompt } from "../src/agent-session/acpmux/model";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key] === undefined) delete scope[key];
    else scope[key] = had[key];
});

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
const SHOT_A = "a".repeat(64);
const SHOT_B = "b".repeat(64);
const PNG_A = "iVBORw0KGgoAAAA=";
const PNG_B = "iVBORw0KGgoAAAB=";

/// A daemon whose chat runs a turn with prompt `p-q` queued behind it: its summary lists the
/// queue (`queue`), its log holds `history`.
function fakeDaemon(queue: unknown[], history: { kind: string; msg: Record<string, unknown> }[]) {
  const events = history.map((step, index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir: "mux",
    ...step,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: true,
    turnCount: 1,
    updatedAt: START,
    queue,
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };
  return () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

async function queueOf(queue: unknown[], history: { kind: string; msg: Record<string, unknown> }[]) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  let shown: QueuedPrompt[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (shown = snapshot.queue),
    undefined,
    fakeDaemon(queue, history),
  );
  await settle();
  client.close?.();
  return shown;
}

const turn = [
  { kind: "user_message", msg: { text: "Fix the layout", promptId: "p-turn", turnId: "turn-1" } },
  { kind: "turn_started", msg: { promptId: "p-turn", turnId: "turn-1" } },
];
const listed = {
  promptId: "p-q",
  prompt: "why does this overlap?",
  turnId: "turn-2",
  queuedAt: START,
  held: false,
  images: [
    { id: SHOT_A, mimeType: "image/png", name: "sidebar.png" },
    { id: SHOT_B, mimeType: "image/png", name: null },
  ],
};

test("the session's queue names a queued prompt's images (a reload or a daemon restart)", async () => {
  // The `queued` record is gone (a restarted daemon's queue, or a page that starts after it).
  const [entry] = await queueOf([listed], turn);
  expect(entry?.images).toEqual([
    { id: SHOT_A, mimeType: "image/png", name: "sidebar.png" },
    { id: SHOT_B, mimeType: "image/png" },
  ]);
});

test("a queued record's images show with their bytes, and an edit's record replaces them", async () => {
  const blocks = [
    { type: "text", text: "why does this overlap?" },
    { type: "image", mimeType: "image/png", data: PNG_A, name: "sidebar.png" },
    { type: "image", mimeType: "image/png", data: PNG_B },
  ];
  const queued = {
    kind: "queued",
    msg: {
      promptId: "p-q",
      text: "why does this overlap?",
      turnId: "turn-2",
      prompt: blocks,
      images: listed.images.map(({ name, ...image }) => (name ? { ...image, name } : image)),
    },
  };
  const [entry] = await queueOf([listed], [...turn, queued]);
  expect(entry?.images).toEqual([
    { id: SHOT_A, mimeType: "image/png", name: "sidebar.png", src: `data:image/png;base64,${PNG_A}` },
    { id: SHOT_B, mimeType: "image/png", src: `data:image/png;base64,${PNG_B}` },
  ]);
  // An edit that kept one image: its record names only that one.
  const updated = {
    kind: "queue_updated",
    msg: {
      promptId: "p-q",
      text: "why does the toolbar overlap?",
      turnId: "turn-2",
      prompt: [blocks[0], blocks[2]],
      images: [{ id: SHOT_B, mimeType: "image/png" }],
    },
  };
  const [edited] = await queueOf(
    [{ ...listed, prompt: "why does the toolbar overlap?", images: [listed.images[1]] }],
    [...turn, queued, updated],
  );
  expect(edited?.prompt).toBe("why does the toolbar overlap?");
  expect(edited?.images).toEqual([{ id: SHOT_B, mimeType: "image/png", src: `data:image/png;base64,${PNG_B}` }]);
});

test("a prompt sent behind the running turn with two images queues a row with both, before acpmux answers", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  type Hooks = { emit: (target: string, step: any) => void };
  // The turn never ends, and the event stream loses acpmux's `queued` record.
  class LaggingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => new Promise<void>(() => undefined));
      const hooks = this as unknown as Hooks;
      const emit = hooks.emit.bind(this);
      hooks.emit = (target, step) => {
        if (step?.mux !== "queued") emit(target, step);
      };
    }
  }
  let snapshot: { queue: QueuedPrompt[]; isWorking?: boolean } = { queue: [] };
  const waiting = new Set<() => void>();
  /// Resolves once `condition` holds, checked as the client publishes each snapshot; fails naming `what`.
  const until = (condition: () => boolean, what: string, timeout = 3_000) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!condition()) return;
        waiting.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        waiting.delete(check);
        reject(new Error(`the pane never showed ${what} within ${timeout} ms`));
      }, timeout);
      waiting.add(check);
      check();
    });
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next as typeof snapshot;
      for (const wake of waiting) wake();
    },
    undefined,
    () => new LaggingHost() as unknown as WebSocket,
  );
  const image = (id: string, name: string, data: string): ComposerAttachment => ({
    id,
    kind: "image",
    name,
    mimeType: "image/png",
    size: 12,
    data,
  });
  try {
    void client.send("start the work").catch(() => undefined);
    await until(() => snapshot.isWorking === true, "the turn running");
    void client
      .send("and look at these", [image("local-1", "sidebar.png", PNG_A), image("local-2", "toolbar.png", PNG_B)])
      .catch(() => undefined);
    await until(() => snapshot.queue.length > 0, "a queued row");
    expect(snapshot.queue.map((entry) => entry.images?.map((each) => [each.name, each.src]))).toEqual([
      [
        ["sidebar.png", `data:image/png;base64,${PNG_A}`],
        ["toolbar.png", `data:image/png;base64,${PNG_B}`],
      ],
    ]);
  } finally {
    client.close?.();
  }
});
