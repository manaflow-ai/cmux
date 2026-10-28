// l10n-allow-file: test fixtures (made-up people and prompts).
// A guest's held prompt in the pane's model (design/chat-multiplayer.md, "Held message card"; THE
// RULE in direct.ts `Hold`): a held prompt is approvable only when the pane holds its authoritative
// record (a `queued` / `queue_updated` record, or `_acpmux/queue_get`) for its current revision; a
// listing never makes it so. Approve names that record's revision, Decline drops it, Needs you only
// reviews it, and an owner's own queued prompt is unchanged.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import type { Participant } from "./multiplayer/participants";

const CY: Participant = { id: "guest:sh-1.g-1", name: "Cy Park" };
const ASK = "Could it also retry on 429?\nAnd honor Retry-After.";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved)
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  // A test that connected a client first keeps its window: the saved globals stay the ones from before it.
  const fresh = !dom;
  dom ??= new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) if (fresh || !saved.has(key)) saved.set(key, scope[key]);
  const w = dom.window;
  const main = w.document.createElement("main");
  main.id = "root";
  w.document.body.append(main);
  Object.assign(scope, {
    window: w,
    document: w.document,
    navigator: w.navigator,
    Node: w.Node,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = main;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

type Daemon = { emit: (target: string, step: unknown) => void };

test("the client sends queue_approve and queue_decline with the right ids", async () => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "document"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  const log: { method: string; params?: Record<string, unknown> }[] = [];
  (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = log;
  saved.set("cmuxGalleryLog", undefined);
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  let shown = {} as AcpmuxSnapshot;
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await until(() => shown.summary !== undefined);
    const id = mockHost.sessionId!;
    const fromCy = { provenance: { kind: "person_message", from: CY.id, fromName: CY.name } };
    const daemon = socket as unknown as Daemon;
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "g-1", text: ASK, awaitingOwner: true, revision: 0, _meta: fromCy },
    });
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "g-2", text: "Keep it short", awaitingOwner: true, _meta: fromCy },
    });
    await until(() => shown.queue?.length === 2);
    expect(shown.queueApproval).toBe(true);
    expect(shown.queue.map((entry) => [entry.id, entry.awaitingOwner, entry.author?.id])).toEqual([
      ["g-1", true, CY.id],
      ["g-2", true, CY.id],
    ]);
    // The guest edits it: still held, at a new revision, which Approve names.
    daemon.emit(id, {
      mux: "queue_updated",
      msg: { promptId: "g-1", text: "Retry on 429 too", awaitingOwner: true, revision: 1, _meta: fromCy },
    });
    await until(() => shown.queue[0]?.revision === 1);
    expect(shown.queue[0]?.awaitingOwner).toBe(true);
    // Approve: acpmux records `queue_approved`, and the prompt waits as any queued prompt.
    // The card names the revision it was drawn with (QueuedMessageCard.tsx).
    await client.answerHeld("g-1", true, shown.queue[0]?.revision);
    await until(() => shown.queue.find((entry) => entry.id === "g-1")?.awaitingOwner === undefined);
    // Decline: the prompt leaves the queue.
    await client.answerHeld("g-2", false);
    await until(() => shown.queue.length === 1);
    const sent = log.filter((each) => each.method.includes("queue_"));
    expect(sent.map((each) => [each.method, each.params])).toEqual([
      ["acpmux _acpmux/queue_approve", { sessionId: id, promptId: "g-1", revision: 1 }],
      ["acpmux _acpmux/queue_decline", { sessionId: id, promptId: "g-2" }],
    ]);
    expect(shown.queue.map((entry) => entry.id)).toEqual(["g-1"]);
  } finally {
    client.close?.();
    delete (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  }
});

test("Needs you never approves a held prompt: Review opens its card, only where acpmux serves Approve", async () => {
  const { needsYouItems } = await import("./needsYou/model");
  const { answerParams } = await import("./needsYou/useNeedsYou");
  const queue = [{ id: "g-1", prompt: ASK, author: CY, awaitingOwner: true, revision: 2 }];
  const open = { sessionId: "s", rows: [], queue };
  expect(needsYouItems({ sessions: [], asks: [], open })).toEqual([]);
  const [item] = needsYouItems({ sessions: [], asks: [], open: { ...open, queueApproval: true } });
  expect(item?.promptId).toBe("g-1");
  expect(item?.answers.map((answer) => answer.id)).toEqual(["review"]);
  // Nothing is sent from the list: the owner answers on the card, which shows the whole message.
  expect(answerParams(item!, item!.answers[0]!)).toBeUndefined();
});

test("Review in Needs you scrolls to the held card and focuses it", async () => {
  const host = await render(<div />);
  const doc = host.ownerDocument;
  const other = doc.createElement("div");
  other.className = "cv-held";
  other.dataset.held = "true";
  other.dataset.queuedMessage = "g-0";
  other.tabIndex = 0;
  const card = doc.createElement("div");
  card.className = "cv-held";
  card.dataset.held = "true";
  card.dataset.queuedMessage = "g-1";
  card.tabIndex = 0;
  let scrolled = false;
  card.scrollIntoView = () => (scrolled = true);
  other.scrollIntoView = () => undefined;
  host.append(other, card);
  const { useNeedsYou } = await import("./needsYou/useNeedsYou");
  let actions: ReturnType<typeof useNeedsYou>["actions"] | undefined;
  function Probe() {
    actions = useNeedsYou({
      snapshot: { sessions: [], asks: [], sessionId: "s", rows: [], queue: [], queueApproval: true },
      callNative: (() => Promise.resolve(undefined)) as never,
      sideSession: () => Promise.resolve(),
    }).actions;
    return null;
  }
  await act(async () => root!.render(<Probe />));
  host.append(other, card);
  actions!.goTo({
    id: "guest:s:g-1",
    kind: "held",
    sessionId: "s",
    ask: ASK,
    who: { name: "chat", chief: false },
    answers: [{ id: "review", label: "review", tone: "choice" }],
    promptId: "g-1",
  });
  expect(scrolled).toBe(true);
  expect(doc.activeElement).toBe(card);
});

test("a prompt the pane sent to an idle chat that acpmux queued leaves no sending bubble", async () => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "document"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  type Hooks = {
    answer: (method: string, params: any) => Promise<unknown>;
    emit: (target: string, step: unknown) => void;
  };
  // Another client's turn started that this pane has not heard of: acpmux queues the owner's
  // prompt (a plain `queued` record, not held) and answers it only when it runs.
  class QueueingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        const promptId = params?._meta?.acpmux?.promptId;
        hooks.emit(String(params.sessionId), { mux: "queued", msg: { promptId, text: "and then this" } });
        return new Promise(() => undefined);
      };
    }
  }
  let shown = {} as AcpmuxSnapshot;
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => new QueueingHost() as unknown as WebSocket,
  );
  try {
    await until(() => shown.summary !== undefined);
    let accepted = false;
    void client.send("and then this", [], undefined, () => (accepted = true)).catch(() => undefined);
    await until(() => shown.queue?.length === 1);
    // Its queued record took it: the composer is free and no sending bubble stays beside the row.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(accepted).toBe(true);
    expect(shown.queue[0]?.awaitingOwner).toBeUndefined();
    expect(shown.rows.filter((row) => row.pending && row.text === "and then this")).toEqual([]);
  } finally {
    client.close?.();
  }
});

/// The real client on the mock daemon, in the DOM `render` installed (or a fresh one).
async function connectedClient() {
  if (!dom) {
    dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
    for (const key of ["window", "document"]) saved.set(key, scope[key]);
    Object.assign(scope, { window: dom.window, document: dom.window.document });
  }
  const log: { method: string; params?: Record<string, unknown> }[] = [];
  (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = log;
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const view = { shown: {} as AcpmuxSnapshot };
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await until(() => view.shown.summary !== undefined);
  const daemon = socket as unknown as {
    emit: (target: string, step: unknown) => void;
    touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  };
  const close = () => {
    client.close?.();
    delete (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  };
  return { client, daemon, view, until, log, id: mockHost.sessionId!, close };
}

const fromCyMeta = { provenance: { kind: "person_message", from: CY.id, fromName: CY.name } };

test("a listed newer revision never joins the text the pane holds: Approve waits for the edit's text", async () => {
  const { daemon, view, until, id, close } = await connectedClient();
  try {
    const before = `Retry on 429. ${"x".repeat(240)}`;
    const after = `${before} And never on 400.`;
    daemon.emit(id, {
      mux: "queued",
      msg: { promptId: "g-1", text: before, awaitingOwner: true, revision: 0, _meta: fromCyMeta },
    });
    await until(() => view.shown.queue?.length === 1);
    // The guest edits past the list's 200-character preview; the list says revision 1 before
    // the edit's own record comes, and its preview matches the text the pane holds.
    const preview = `${after.slice(0, 200)}…`;
    daemon.touch(id, {
      queue: [{ promptId: "g-1", prompt: preview, fromAgent: null, author: CY, awaitingOwner: true, revision: 1 }],
    });
    await until(() => view.shown.queue[0]?.updating === true);
    expect(view.shown.queue[0]).toMatchObject({ prompt: before, revision: 0, updating: true, awaitingOwner: true });
    // The edit's record brings the whole text with its revision: Approve may name it now.
    daemon.emit(id, {
      mux: "queue_updated",
      msg: { promptId: "g-1", text: after, awaitingOwner: true, revision: 1, _meta: fromCyMeta },
    });
    await until(() => view.shown.queue[0]?.updating === undefined);
    expect(view.shown.queue[0]).toMatchObject({ prompt: after, revision: 1 });
  } finally {
    close();
  }
});

test("a list older than the held text the pane read is ignored: no stuck Updating…", async () => {
  const { mergeQueue } = await import("./direct");
  const before = `Retry on 429. ${"x".repeat(240)}`;
  const after = `${before} And never on 400.`;
  // Revision 1's record came live while the attach was out; its older snapshot lists revision 0,
  // whose preview is revision 1's too (the edit is past the 200-character cut).
  const current = [{ id: "g-1", prompt: after, author: CY, awaitingOwner: true, revision: 1, listedRevision: 1 }];
  const listed = [
    {
      promptId: "g-1",
      prompt: `${before.slice(0, 200)}…`,
      fromAgent: null,
      author: CY,
      awaitingOwner: true,
      revision: 0,
    },
  ];
  const [entry] = mergeQueue(current, listed);
  expect(entry).toMatchObject({ prompt: after, revision: 1, awaitingOwner: true });
  expect(entry?.updating).toBeUndefined();
  // A list that names a newer revision than the text still waits for its record.
  const [ahead] = mergeQueue(current, [{ ...listed[0], revision: 2 }]);
  expect(ahead).toMatchObject({ prompt: after, revision: 1, updating: true });
});

test("a held prompt whose record is older than the opened page reads it, then can be approved", async () => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "document"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  const log: { method: string; params?: Record<string, unknown> }[] = [];
  (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = log;
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  type Hooks = {
    answer: (method: string, params: any) => Promise<any>;
    record: (target: string, step: unknown) => unknown;
    sessions: { sessionId: string; queue?: unknown }[];
  };
  // A long chat: the attach's first page starts after the guest's `queued` record, and acpmux's
  // list names the held prompt by its 200-character preview only.
  class LongChat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        const result = await answer(method, params);
        if (method !== "_acpmux/attach") return result;
        return { ...result, events: result.events.filter((event: any) => event.kind !== "queued"), hasMore: true };
      };
    }
  }
  const socket = new LongChat();
  const daemon = socket as unknown as Hooks;
  const id = mockHost.sessionId!;
  const text = `Retry on 429. ${"x".repeat(240)} And never on 400.`;
  // The daemon's history before this pane connects (recorded, never delivered live): the
  // guest's held prompt, and its list entry by preview.
  daemon.record(id, {
    mux: "queued",
    msg: { promptId: "g-1", text, awaitingOwner: true, revision: 0, _meta: fromCyMeta },
  });
  const session = daemon.sessions.find((entry) => entry.sessionId === id)!;
  session.queue = [
    {
      promptId: "g-1",
      prompt: `${text.slice(0, 200)}…`,
      fromAgent: null,
      author: CY,
      awaitingOwner: true,
      revision: 0,
    },
  ];
  let shown = {} as AcpmuxSnapshot;
  const seen: AcpmuxSnapshot["queue"][] = [];
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot as AcpmuxSnapshot;
      if (shown.queue?.length) seen.push(shown.queue);
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await until(() => shown.queue?.[0]?.revision === 0);
    // Its page had the preview alone (no Approve until the record): the pane read that prompt's record.
    expect(seen.every((queue) => queue[0]?.updating === true || queue[0]?.prompt === text)).toBe(true);
    expect(log.filter((each) => each.method === "acpmux _acpmux/queue_get").map((each) => each.params)).toEqual([
      { sessionId: id, promptId: "g-1" },
    ]);
    // No history paging for it.
    expect(log.some((each) => JSON.stringify(each.params?.kinds)?.includes("queue_updated"))).toBe(false);
    // Then its whole text with the record's revision: approvable.
    expect(shown.queue[0]).toMatchObject({ prompt: text, revision: 0, awaitingOwner: true });
    expect(shown.queue[0]?.updating).toBeUndefined();
  } finally {
    client.close?.();
    delete (globalThis as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  }
});

/// A mock daemon whose history (recorded before the pane connects) holds a guest's prompt that the
/// attach page leaves out, listed by preview; its held-record reads wait while `gate` holds them.
function coldHeldChat(text: string, images?: unknown[]) {
  return async (MockAcpmuxSocket: any) => {
    ensureDom();
    type Hooks = {
      answer: (method: string, params: any) => Promise<any>;
      record: (target: string, step: unknown) => unknown;
      sessions: { sessionId: string; queue?: unknown }[];
    };
    const gate = {
      held: false,
      waiting: [] as (() => void)[],
      release() {
        this.held = false;
        for (const go of this.waiting.splice(0)) go();
      },
    };
    class LongChat extends MockAcpmuxSocket {
      constructor() {
        super(() => Promise.resolve());
        const hooks = this as unknown as Hooks;
        const answer = hooks.answer.bind(this);
        hooks.answer = async (method, params) => {
          const heldRead = method === "_acpmux/queue_get";
          if (heldRead && gate.held) await new Promise<void>((resolve) => gate.waiting.push(resolve));
          const result = await answer(method, params);
          if (method !== "_acpmux/attach") return result;
          return { ...result, events: result.events.filter((event: any) => event.kind !== "queued"), hasMore: true };
        };
      }
    }
    const { mockHost } = await import("./mock");
    const id = mockHost.sessionId!;
    // Made right before the client connects: the mock opens on a microtask, which an await between
    // would miss.
    const socket = () => {
      const made = new LongChat();
      seed(made as unknown as Hooks);
      return made;
    };
    const seed = (daemon: Hooks) => {
      daemon.record(id, {
        mux: "queued",
        msg: {
          promptId: "g-1",
          text,
          awaitingOwner: true,
          revision: 1,
          ...(images ? { images } : {}),
          _meta: fromCyMeta,
        },
      });
      daemon.sessions.find((entry) => entry.sessionId === id)!.queue = [
        {
          promptId: "g-1",
          prompt: `${text.slice(0, 200)}…`,
          fromAgent: null,
          author: CY,
          awaitingOwner: true,
          revision: 1,
          images: [{ id: "a".repeat(64), mimeType: "image/png", name: "old.png" }],
        },
      ];
    };
    return { socket, gate, id };
  };
}

/// The window the client and the mock daemon run in: installed before either is made.
function ensureDom(): void {
  if (dom) return;
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  for (const key of ["window", "document"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
}

async function openClient(makeSocket: () => unknown) {
  ensureDom();
  const { AcpmuxDirectClient } = await import("./direct");
  const { mockHost } = await import("./mock");
  const socket = makeSocket();
  const view = { shown: {} as AcpmuxSnapshot };
  const waiters: (() => void)[] = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => waiters.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as AcpmuxSnapshot;
      for (const wake of waiters.splice(0)) wake();
    },
    undefined,
    () => socket as WebSocket,
  );
  return { client, view, until };
}

const LONG = `Retry on 429. ${"x".repeat(240)} And never on 400.`;

test("leaving and reopening a chat while its held record is being read still makes the card approvable", async () => {
  const { MockAcpmuxSocket } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { socket, gate, id } = await coldHeldChat(LONG)(MockAcpmuxSocket);
  gate.held = true;
  const { client, view, until } = await openClient(socket);
  try {
    // The first read is out and waits; the pane leaves the chat and comes back.
    await until(() => view.shown.queue?.[0]?.updating === true && gate.waiting.length === 1);
    const other = mockSessions.find((entry) => entry.sessionId !== id)!.sessionId;
    await client.select(other);
    await client.select(id);
    await until(() => view.shown.sessionId === id && view.shown.queue?.[0]?.updating === true);
    // The reopened chat reads again; the read from before the switch lands last and is dropped.
    await until(() => gate.waiting.length === 2);
    const [first, second] = gate.waiting.splice(0);
    second!();
    await until(() => view.shown.queue?.[0]?.updating === undefined);
    first!();
    gate.held = false;
    expect(view.shown.queue[0]).toMatchObject({ prompt: LONG, revision: 1, awaitingOwner: true });
  } finally {
    gate.release();
    client.close?.();
  }
});

test("a held prompt's images are its record's own, with its revision", async () => {
  const { MockAcpmuxSocket } = await import("./mock");
  const recordImage = { id: "b".repeat(64), mimeType: "image/png", name: "new.png" };
  const { socket } = await coldHeldChat(LONG, [recordImage])(MockAcpmuxSocket);
  const { client, view, until } = await openClient(socket);
  try {
    await until(() => view.shown.queue?.[0]?.revision === 1 && view.shown.queue[0]?.updating === undefined);
    // The list's preview named another image; the record read with revision 1 names its own.
    expect(view.shown.queue[0]?.images?.map((image) => image.id)).toEqual([recordImage.id]);
  } finally {
    client.close?.();
  }
  // Kept text (a stale or same-revision listing) keeps the record's images too.
  const { mergeQueue } = await import("./direct");
  const had = [
    { id: "g-1", prompt: LONG, author: CY, awaitingOwner: true, revision: 2, listedRevision: 2, images: [recordImage] },
  ];
  const listed = {
    promptId: "g-1",
    prompt: `${LONG.slice(0, 200)}…`,
    fromAgent: null,
    author: CY,
    awaitingOwner: true,
    images: [{ id: "a".repeat(64), mimeType: "image/png" }],
  };
  for (const revision of [1, 2, 3]) {
    const [entry] = mergeQueue(had, [{ ...listed, revision }]);
    expect([revision, entry?.revision, entry?.images?.map((image) => image.id)]).toEqual([
      revision,
      2,
      [recordImage.id],
    ]);
  }
});

test("a listing never makes a held prompt approvable, whatever its preview", async () => {
  const { mergeQueue } = await import("./direct");
  // A short message: acpmux's preview is its whole text, with no "…".
  const listed = [
    { promptId: "g-1", prompt: "Retry on 429", fromAgent: null, author: CY, awaitingOwner: true, revision: 0 },
  ];
  const [entry] = mergeQueue([], listed);
  expect(entry).toMatchObject({ prompt: "Retry on 429", awaitingOwner: true, updating: true });
  expect(entry?.revision).toBeUndefined();
  // Its record (a `queued` record, or queue_get) is what makes it approvable, at its revision.
  const [recorded] = mergeQueue([{ ...entry!, prompt: "Retry on 429", revision: 0, updating: undefined }], listed);
  expect(recorded).toMatchObject({ revision: 0 });
  expect(recorded?.updating).toBeUndefined();
});

test("without acpmux's queue_get a held card whose record the pane lacks stays Updating, never approvable", async () => {
  const { MockAcpmuxSocket } = await import("./mock");
  const { socket } = await coldHeldChat(LONG)(MockAcpmuxSocket);
  type Hooks = { answer: (method: string, params: any) => Promise<any> };
  const log: string[] = [];
  const make = () => {
    const made = socket() as unknown as Hooks;
    const answer = made.answer.bind(made);
    made.answer = async (method, params) => {
      log.push(method);
      const result = await answer(method, params);
      // An acpmux before queue_get: it names no `queueGet` feature.
      if (method === "initialize") result._meta.acpmux.features = ["queueApproval"];
      return result;
    };
    return made;
  };
  const { client, view, until } = await openClient(make);
  try {
    await until(() => view.shown.queue?.[0]?.updating === true);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(log).not.toContain("_acpmux/queue_get");
    expect(view.shown.queue[0]?.updating).toBe(true);
  } finally {
    client.close?.();
  }
});
