// A shared chat: a teammate's queued prompt keeps its author on every path that rebuilds the
// pane's queue (its `queued` record, an edit, a reorder or send-now, acpmux's own list, and the
// rows read again once a sender's chat is listed), so its row never offers the person an action
// acpmux refuses with `queue.not_author` (ComposerQueue.tsx).
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
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  deliver: (message: unknown) => void;
};
type Entry = { id: string; prompt: string; next?: boolean; author?: { id: string; name: string }; message?: unknown };
type Shown = { summary?: unknown; queue?: Entry[]; isWorking?: boolean };

const ana = { id: "tailnet:ana@example.com", name: "Ana" };
const fromAna = { provenance: { kind: "person_message", from: ana.id, fromName: ana.name } };

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
  return { client, socket, daemon, view, until, id: mockHost.sessionId!, close: () => client.close?.() };
}

const authors = (shown: Shown) => (shown.queue ?? []).map((entry) => [entry.id, entry.author?.name ?? null]);
const sender = (shown: Shown, id: string) =>
  (shown.queue?.find((entry) => entry.id === id)?.message as { name?: string } | undefined)?.name;

test("a teammate's queued prompt keeps its author through edits, reorders, the list and a re-read", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-ana", text: "Rebase first", _meta: fromAna } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-me", text: "Then run the tests" } });
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-bot", text: "Build is green", fromAgent: "builder" } });
    // Addressed from the CLI by a chat not listed yet: its sender waits to be checked (recheckSenders).
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "p-cli", text: "builder -> worker: Lint is green", client: "acpmux-cli#7" },
    });
    await until(() => view.shown.queue?.length === 4);
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
      ["p-bot", null],
      ["p-cli", null],
    ]);
    expect(sender(view.shown, "p-cli")).toBeUndefined();
    // Ana's own edit keeps her provenance, so her row keeps her name.
    daemon.emit(id, {
      mux: "queue_updated",
      msg: { promptId: "p-ana", text: "Rebase onto main first", _meta: fromAna },
    });
    await until(() => view.shown.queue?.[0]?.prompt === "Rebase onto main first");
    expect(view.shown.queue?.[0]?.author).toEqual(ana);
    // Sent now: every row is rebuilt, and the one sent now goes first.
    daemon.emit(id, {
      mux: "queue_order",
      msg: { promptId: "p-me", next: true, order: ["p-me", "p-ana", "p-bot", "p-cli"] },
    });
    await until(() => view.shown.queue?.[0]?.id === "p-me");
    expect(authors(view.shown)).toEqual([
      ["p-me", null],
      ["p-ana", "Ana"],
      ["p-bot", null],
      ["p-cli", null],
    ]);
    // acpmux's own list (a session change that carries the queue) names no author: the pane keeps it.
    daemon.touch(id, {
      queue: [
        { promptId: "p-ana", prompt: "Rebase onto main first", fromAgent: null },
        { promptId: "p-me", prompt: "Then run the tests", fromAgent: null },
        { promptId: "p-bot", prompt: "Build is green", fromAgent: "builder" },
        { promptId: "p-cli", prompt: "builder -> worker: Lint is green", fromAgent: null },
      ],
    });
    await until(() => view.shown.queue?.[0]?.id === "p-ana");
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
      ["p-bot", null],
      ["p-cli", null],
    ]);
    // The sender's chat is listed: the rows are read again (recheckSenders), the CLI prompt reads
    // as builder's message, and Ana's row keeps her name.
    daemon.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { kind: "updated", session: { sessionId: "acp_builder", name: "builder", status: "idle", updatedAt: 1 } },
    });
    await until(() => sender(view.shown, "p-cli") === "builder");
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
      ["p-bot", null],
      ["p-cli", null],
    ]);
  } finally {
    close();
  }
});

test("a teammate's edit in an attach's page keeps their name when the queued record is older than the page", async () => {
  const { client, socket, daemon, view, until, close } = await pane();
  const mock = socket as unknown as {
    sessions: Array<Record<string, unknown>>;
    record: (target: string, step: unknown) => void;
  };
  try {
    const paged = "acp_paged";
    // The `queued` record, then more records than an attach's page holds (400), then Ana's edit.
    mock.record(paged, { mux: "queued", msg: { promptId: "p-ana", text: "Rebase first", _meta: fromAna } });
    for (let n = 0; n < 450; n += 1) mock.record(paged, { mux: "mock_filler", msg: { n } });
    mock.record(paged, { mux: "queue_updated", msg: { promptId: "p-ana", text: "Rebase onto main", _meta: fromAna } });
    mock.record(paged, { mux: "queued", msg: { promptId: "p-me", text: "Then run the tests" } });
    const session = {
      ...mock.sessions[0],
      sessionId: paged,
      name: "paged",
      queue: [
        { promptId: "p-ana", prompt: "Rebase onto main", fromAgent: null },
        { promptId: "p-me", prompt: "Then run the tests", fromAgent: null },
      ],
    };
    mock.sessions.push(session);
    daemon.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session } });
    await client.select(paged);
    await until(() => view.shown.queue?.length === 2);
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
    ]);
  } finally {
    close();
  }
});

test("a delivery change rebuilds a waiting prompt's row and keeps its author", async () => {
  const { deliveryTiming } = await import("./direct");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 150, failMs: 60_000 });
  const { client, socket, daemon, view, until, id, close } = await pane();
  // acpmux never answers the prompt, so its delivery stays `sending` until the slow mark.
  const hooks = socket as unknown as { answer: (method: string, params: unknown) => unknown };
  const answer = hooks.answer.bind(socket);
  hooks.answer = (method, params) =>
    method === "session/prompt" ? new Promise(() => undefined) : answer(method, params);
  try {
    daemon.emit(id, { mux: "turn_started", msg: {} });
    // The turn runs before the send, so the prompt waits in the queue.
    await until(() => view.shown.isWorking === true);
    void client.send("Rebase first", [], "p-mine").catch(() => undefined);
    await until(() => view.shown.queue?.some((entry) => entry.id === "p-mine") === true);
    // Edited before acpmux answered: the record names its author (a teammate's pane, whose prompts
    // the host stamps) and the row stops showing it sending.
    daemon.emit(id, { mux: "queue_updated", msg: { promptId: "p-mine", text: "Rebase onto main", _meta: fromAna } });
    await until(() => view.shown.queue?.[0]?.prompt === "Rebase onto main");
    // Still unanswered at the slow mark: the row is rebuilt as sending again (setDelivery).
    await until(() => (view.shown.queue?.[0] as { sending?: boolean } | undefined)?.sending === true);
    expect(view.shown.queue?.[0]?.author).toEqual(ana);
  } finally {
    hooks.answer = answer;
    Object.assign(deliveryTiming, timing);
    close();
  }
});

test("a switch back to a chat whose kept tail lost the authored record keeps the teammate's name", async () => {
  const { client, socket, daemon, view, until, id, close } = await pane();
  const mock = socket as unknown as {
    sessions: Array<Record<string, unknown>>;
    record: (target: string, step: unknown) => void;
  };
  try {
    const shared = "acp_shared";
    mock.record(shared, { mux: "queued", msg: { promptId: "p-ana", text: "Rebase first", _meta: fromAna } });
    mock.record(shared, { mux: "queued", msg: { promptId: "p-me", text: "Then run the tests" } });
    const session = {
      ...mock.sessions[0],
      sessionId: shared,
      name: "shared",
      queue: [
        { promptId: "p-ana", prompt: "Rebase first", fromAgent: null },
        { promptId: "p-me", prompt: "Then run the tests", fromAgent: null },
      ],
    };
    mock.sessions.push(session);
    daemon.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session } });
    await client.select(shared);
    await until(() => view.shown.queue?.length === 2);
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
    ]);
    // More records than a kept tail holds (400) arrive while the chat is shown, so neither the tail
    // kept on the switch away nor the attach page on the way back holds Ana's `queued` record.
    for (let n = 0; n < 450; n += 1) daemon.emit(shared, { mux: "mock_filler", msg: { n } });
    // The last of them is read before the switch away (live records arrive asynchronously).
    daemon.emit(shared, { mux: "queue_updated", msg: { promptId: "p-me", text: "Then run the tests twice" } });
    await until(() => view.shown.queue?.[1]?.prompt === "Then run the tests twice");
    await client.select(id);
    await until(() => (view.shown.queue ?? []).length === 0);
    await client.select(shared);
    await until(() => view.shown.queue?.length === 2);
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
    ]);
  } finally {
    close();
  }
});

test("a cold open whose page holds no authored record takes the author acpmux lists", async () => {
  const { client, socket, daemon, view, until, close } = await pane();
  const mock = socket as unknown as {
    sessions: Array<Record<string, unknown>>;
    record: (target: string, step: unknown) => void;
  };
  try {
    const cold = "acp_cold";
    // Ana's `queued` record, then more records than an attach's page holds (400), and no edit
    // since: only acpmux's list says whose the prompt is (after an app restart, say).
    mock.record(cold, { mux: "queued", msg: { promptId: "p-ana", text: "Rebase first", _meta: fromAna } });
    for (let n = 0; n < 450; n += 1) mock.record(cold, { mux: "mock_filler", msg: { n } });
    mock.record(cold, { mux: "queued", msg: { promptId: "p-me", text: "Then run the tests" } });
    const session = {
      ...mock.sessions[0],
      sessionId: cold,
      name: "cold",
      queue: [
        { promptId: "p-ana", prompt: "Rebase first", fromAgent: null, author: ana },
        { promptId: "p-me", prompt: "Then run the tests", fromAgent: null, author: null },
      ],
    };
    mock.sessions.push(session);
    daemon.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session } });
    await client.select(cold);
    await until(() => view.shown.queue?.length === 2);
    expect(authors(view.shown)).toEqual([
      ["p-ana", "Ana"],
      ["p-me", null],
    ]);
  } finally {
    close();
  }
});

test("a list that names the owner (author null) wins over an author the pane kept", async () => {
  const { daemon, view, until, id, close } = await pane();
  try {
    daemon.emit(id, { mux: "queued", msg: { promptId: "p-x", text: "Rebase first", _meta: fromAna } });
    await until(() => view.shown.queue?.[0]?.author?.name === "Ana");
    // acpmux, which lists authors, says this prompt is the owner's: the pane's own record loses.
    daemon.touch(id, { queue: [{ promptId: "p-x", prompt: "Rebase first", fromAgent: null, author: null }] });
    await until(() => view.shown.queue?.[0]?.author === undefined);
    expect(authors(view.shown)).toEqual([["p-x", null]]);
  } finally {
    close();
  }
});
