// A queued message the pane knows only by acpmux's cut preview (direct.ts `mergeQueue`, after a
// reload) stays marked a preview on every path that rebuilds the queue, so the waiting group never
// folds two distinct messages that share their first 200 characters (pendingMessages.ts). Review at
// 08d5800d46ab: Send now on another entry (`queue_order`) rebuilt every entry without the mark, the
// two became twins, and Dismiss on one deleted both.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { pendingMessagesRow } from "../src/agent-session/acpmux/conversation/pendingMessages";
import { queuedMessageRows } from "../src/agent-session/acpmux/conversation/queuedMessages";
import type { QueuedPrompt } from "../src/agent-session/acpmux/model";

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
};
type Shown = { summary?: unknown; queue?: QueuedPrompt[] };

async function pane() {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const view = { shown: {} as Shown };
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
  await until(() => view.shown.summary !== undefined);
  return { daemon: socket as unknown as Daemon, view, until, id: mockHost.sessionId!, close: () => client.close?.() };
}

const preview = `${"cmux#27602 review: ".padEnd(200, "x")}…`;
const shownIds = (queue: QueuedPrompt[]) =>
  pendingMessagesRow([], queuedMessageRows(queue))!.pendingMessages!.rows.map((row) => [
    row.queuedMessage?.promptId,
    row.queuedMessage?.twins ?? [],
  ]);

test("Send now on another entry keeps two cut previews apart", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.touch(id, {
      queue: [
        { promptId: "p-first", prompt: preview, fromAgent: "nx-sidebar" },
        { promptId: "p-second", prompt: preview, fromAgent: "nx-sidebar" },
        { promptId: "p-other", prompt: "Build is green", fromAgent: "builder" },
      ],
    });
    await until(() => view.shown.queue?.length === 3);
    expect(shownIds(view.shown.queue!)).toEqual([
      ["p-first", []],
      ["p-second", []],
      ["p-other", []],
    ]);
    // Send now on the third: acpmux records the new order, and every entry is rebuilt.
    daemon.emit(id, {
      mux: "queue_order",
      msg: { promptId: "p-other", next: true, order: ["p-other", "p-first", "p-second"] },
    });
    await until(() => view.shown.queue?.[0]?.id === "p-other");
    expect(view.shown.queue!.filter((entry) => entry.preview).map((entry) => entry.id)).toEqual([
      "p-first",
      "p-second",
    ]);
    expect(shownIds(view.shown.queue!)).toEqual([
      ["p-other", []],
      ["p-first", []],
      ["p-second", []],
    ]);
  } finally {
    close();
  }
});
