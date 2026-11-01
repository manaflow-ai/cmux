// l10n-allow-file: test fixture prompts, not shipped UI.
// Other agents' messages a person's Stop holds (acpmux `queue_paused` with `reason: "stop"`,
// hub/cancel.rs) wait until the person's next turn completes or the queue is resumed, not for the
// turn to end. Their cards said "Read after this turn" all the same, and nothing in the pane read
// the hold (Leo, 2026-10-29: "this is so awkward the stop button doesnt really work and resume
// doesnt really appear!?"). Now the first card says they are held and what lets them in.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "./i18n";
import type { QueuedPrompt } from "./model";
import { QueuedMessageCard } from "./conversation/QueuedMessageCard";
import { queuedMessageRows } from "./conversation/queuedMessages";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = new Map(keys.filter((key) => key in scope).map((key) => [key, scope[key]]));

beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const key of keys)
    if (saved.has(key)) scope[key] = saved.get(key);
    else delete scope[key];
});

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};
type Shown = { summary?: unknown; queue?: QueuedPrompt[] };

async function pane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
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
  return { daemon, view, until, id: mockHost.sessionId!, close: () => client.close?.() };
}

const held = (shown: Shown) => (shown.queue ?? []).map((entry) => [entry.id, entry.heldByStop === true]);
/// The lead line over the queued agent messages, as the transcript draws it.
const lead = async (shown: Shown) => {
  const first = queuedMessageRows(shown.queue ?? [])[0];
  if (!first) return undefined;
  const container = dom.window.document.createElement("div");
  const root = createRoot(container);
  await act(async () => root.render(<QueuedMessageCard row={first} onOpen={() => undefined} />));
  const text = container.querySelector(".cv-received__queued-head")?.textContent ?? undefined;
  await act(async () => root.unmount());
  return text;
};
const listed = (id: string, fromAgent: string | null, isHeld: boolean) => ({
  promptId: id,
  turnId: `t-${id}`,
  client: "test",
  prompt: id,
  queuedAt: 1,
  held: isHeld,
  fromAgent,
});

test("other agents' messages a Stop holds say so, and what lets them in, until they are let go", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "turn_started", msg: { turnId: "t-1" } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-a", text: "Build is green", fromAgent: "builder" } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-b", text: "Lint is green", fromAgent: "linter" } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-me", text: "Then run the tests" } });
    await until(() => view.shown.queue?.length === 3);
    expect(await lead(view.shown)).toBeUndefined();
    // The person's Stop: acpmux holds the agents' messages, and the turn ends stopped.
    daemon.emit(id, { mux: "queue_paused", msg: { stoppedTurnId: "t-1", held: ["p-a", "p-b"], reason: "stop" } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "cancelled", turnId: "t-1" } });
    await until(() => view.shown.queue?.[0]?.heldByStop === true);
    expect(held(view.shown)).toEqual([
      ["p-a", true],
      ["p-b", true],
      ["p-me", false],
    ]);
    expect(await lead(view.shown)).toBe(translate("message.heldByStop"));
    // acpmux's own list keeps them held while it lists them held.
    daemon.touch(id, {
      status: "ready",
      queuePaused: true,
      queue: [listed("p-a", "builder", true), listed("p-b", "linter", true), listed("p-me", null, false)],
    });
    await until(() => view.shown.queue?.every((entry) => entry.prompt !== "") === true);
    expect(held(view.shown)).toEqual([
      ["p-a", true],
      ["p-b", true],
      ["p-me", false],
    ]);
    // One let go by name; then the rest, by a resume that names none.
    daemon.emit(id, { mux: "queue_resumed", msg: { queued: 3, promptIds: ["p-a"] } });
    await until(() => view.shown.queue?.[0]?.heldByStop !== true);
    expect(held(view.shown)).toEqual([
      ["p-a", false],
      ["p-b", true],
      ["p-me", false],
    ]);
    expect(await lead(view.shown)).toBeUndefined();
    daemon.emit(id, { mux: "queue_resumed", msg: { queued: 3 } });
    await until(() => view.shown.queue?.[1]?.heldByStop !== true);
    expect(held(view.shown).every(([, isHeld]) => !isHeld)).toBe(true);
  } finally {
    close();
  }
});

test("a list that names a held message unheld lets it go; a failed turn's hold is not a Stop's", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-a", text: "Build is green", fromAgent: "builder" } });
    daemon.emit(id, { mux: "queue_paused", msg: { held: ["p-a"], reason: "stop" } });
    await until(() => view.shown.queue?.[0]?.heldByStop === true);
    daemon.touch(id, { status: "ready", queue: [listed("p-a", "builder", false)] });
    await until(() => view.shown.queue?.[0]?.heldByStop !== true);
    // A failed turn holds the queue too (`queue_paused` with no reason): the composer's paused
    // note says so (ComposerQueue.tsx), not the Stop's line.
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-b", text: "Lint is green", fromAgent: "linter" } });
    daemon.emit(id, { mux: "queue_paused", msg: { turnId: "t-2", held: ["p-a", "p-b"] } });
    daemon.emit(id, { mux: "turn_result", msg: { status: "failed", turnId: "t-2" } });
    await until(() => view.shown.queue?.length === 2);
    expect(held(view.shown).every(([, isHeld]) => !isHeld)).toBe(true);
    expect(await lead(view.shown)).toBeUndefined();
  } finally {
    close();
  }
});

test("acpmux's list says which messages a Stop holds, also with no record of it, and an edit keeps it", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    // An attach whose page holds none of the Stop's records: the list alone says so.
    daemon.touch(id, {
      status: "ready",
      queuePaused: true,
      queue: [
        { ...listed("p-a", "builder", true), heldByStop: true },
        { ...listed("p-b", "linter", true), heldByStop: false },
      ],
    });
    await until(() => view.shown.queue?.length === 2);
    expect(held(view.shown)).toEqual([
      ["p-a", true],
      ["p-b", false],
    ]);
    expect(await lead(view.shown)).toBe(translate("message.heldByStop"));
    // A reorder rebuilds every entry; the hold stays.
    daemon.emit(id, { mux: "queue_order", msg: { order: ["p-b", "p-a"], promptId: "p-b", next: true } });
    await until(() => view.shown.queue?.[0]?.id === "p-b");
    expect(held(view.shown)).toEqual([
      ["p-b", false],
      ["p-a", true],
    ]);
    // A list that says the Stop no longer holds it lets it go.
    daemon.touch(id, {
      status: "ready",
      queue: [
        { ...listed("p-b", "linter", false), heldByStop: false },
        { ...listed("p-a", "builder", true), heldByStop: false },
      ],
    });
    await until(() => view.shown.queue?.every((entry) => !entry.heldByStop) === true);
  } finally {
    close();
  }
});

test("Send now lets a held message go; an edit makes it the person's, which no Stop holds", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-a", text: "Build is green", fromAgent: "builder" } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-b", text: "Lint is green", fromAgent: "linter" } });
    daemon.emit(id, { mux: "queue_paused", msg: { held: ["p-a", "p-b"], reason: "stop" } });
    await until(() => view.shown.queue?.every((entry) => entry.heldByStop) === true);
    // Send now (hub/queue.rs `put_next`): it runs next, held no more; the other stays held.
    daemon.emit(id, { mux: "queue_order", msg: { order: ["p-b", "p-a"], promptId: "p-b", next: true } });
    await until(() => view.shown.queue?.[0]?.id === "p-b");
    expect(held(view.shown)).toEqual([
      ["p-b", false],
      ["p-a", true],
    ]);
    // Edited, it is the person's prompt (hub/queue_edit.rs): not a held agent message.
    daemon.emit(id, { mux: "queue_updated", msg: { promptId: "p-a", text: "Build is green, ship it" } });
    await until(() => view.shown.queue?.[1]?.prompt === "Build is green, ship it");
    expect(held(view.shown)).toEqual([
      ["p-b", false],
      ["p-a", false],
    ]);
  } finally {
    close();
  }
});
