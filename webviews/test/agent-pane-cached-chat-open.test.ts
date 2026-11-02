// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A chat this page already read draws from the tail its last visit left, on the frame the switch
// lands, while its attach refreshes it behind that (direct.ts `keptTails`, Leo 2026-10-20: a chat
// "should be instant if cached"; the frame timing is test/chat-open-perf.test.ts). What the tail
// says about the chat's past is drawn; what it says about what the chat is *doing* must not be,
// because the chat ran on while the reader was away. These hold the client to that:
//
//   - the frame back draws the chat, before its attach answers;
//   - a chat that ran on past one attach page comes back without a hole in its transcript;
//   - an ask answered while away does not come back as a card;
//   - a turn that ended while away does not come back as a running turn;
//   - a queued prompt keeps its whole text, not acpmux's preview;
//   - a chat whose attach fails does not stay on screen as if it had been read.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 20, 9, 0, 0);
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(() => {
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

type Message = { id?: number; method: string; params?: Record<string, unknown> };
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
/** An attach reply: the page acpmux answers for a chat, and whether it holds older records. */
type Page = { events: Step[]; from?: number; hasMore?: boolean; queue?: { promptId: string; prompt: string }[] };

const events = (sessionId: string, page: Page) =>
  page.events.map(([dir, kind, msg], at) => {
    const seq = (page.from ?? 1) + at;
    return { sessionId, seq, at: START + seq * 1000, dir, kind, msg };
  });

const prompt = (text: string): Step => ["mux", "user_message", { text }];
const reply = (sessionId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];
const TURN_STARTED: Step = ["mux", "turn_started", {}];
const TURN_DONE: Step = ["mux", "turn_result", { status: "completed" }];
const ASKING: Step = [
  "mux",
  "permission_request",
  {
    permissionId: "p1",
    request: {
      toolCall: { toolCallId: "e1", title: "Edit install.sh", kind: "edit" },
      options: [
        { optionId: "allow", name: "Allow", kind: "allow_once" },
        { optionId: "deny", name: "Deny", kind: "reject_once" },
      ],
    },
  },
];

/**
 * acpmux for two chats. Each chat's attach answers `pages` in order (the last one again once they
 * run out), so a chat can come back changed; `hold` keeps the next attach of a chat unanswered,
 * and `fail` refuses it.
 */
class Daemon {
  /// The two chats this run uses. Each test names its own, because the kept tails outlive a test
  /// (they are the page's memory, module state), and a test must not draw another's chat.
  readonly sessionA: string;
  readonly sessionB: string;
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];
  readonly pages = new Map<string, Page[]>();
  readonly status = new Map<string, string>();
  readonly listedQueue = new Map<string, { promptId: string; prompt: string }[]>();
  hold?: string;
  fail?: string;
  /// Refuses a detach, as acpmux does for a chat it no longer resolves.
  refuseDetach = false;
  /// Holds every detach of this chat unanswered while set, as a busy acpmux does.
  holdDetach?: string;
  private heldDetaches: Message[] = [];
  /** Answers a detach held back: the oldest, or the newest (acpmux runs each request on its own
   * task, so a later detach can be answered first). */
  releaseDetach(which: "oldest" | "newest" = "oldest"): void {
    const message = which === "oldest" ? this.heldDetaches.shift() : this.heldDetaches.pop();
    if (message) this.answer(message);
  }
  private held?: Message;
  private holding?: () => void;
  /** Resolves when the held attach has been asked for. */
  asked = new Promise<void>((resolve) => (this.holding = resolve));
  private attached = new Map<string, number>();
  /// Holds the next older-history read of this chat (`_acpmux/events` with a `beforeSeq`).
  holdOlder?: string;
  private heldOlder?: Message;
  private holdingOlder?: () => void;
  /** Resolves when the held older-history read has been asked for. */
  askedOlder = new Promise<void>((resolve) => (this.holdingOlder = resolve));
  /// The older records this chat answers for a read before its page.
  readonly older = new Map<string, Page>();

  constructor(name: string) {
    this.sessionA = `${name}-a`;
    this.sessionB = `${name}-b`;
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    this.sent.push(message);
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/detach" && sessionId === this.holdDetach) {
      this.heldDetaches.push(message);
      return;
    }
    if (message.method === "_acpmux/attach" && sessionId === this.hold) {
      this.held = message;
      this.hold = undefined;
      this.holding?.();
      return;
    }
    if (
      message.method === "_acpmux/events" &&
      message.params?.beforeSeq !== undefined &&
      sessionId === this.holdOlder
    ) {
      this.heldOlder = message;
      this.holdOlder = undefined;
      this.holdingOlder?.();
      return;
    }
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  /** Tells the pane a chat changed, as acpmux does while the reader is on another one. */
  changed(sessionId: string): void {
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { kind: "updated", session: this.summary(sessionId) },
      }),
    });
  }

  /** Answers the attach held back, as acpmux would once it caught up. */
  release(): void {
    const message = this.held;
    this.held = undefined;
    this.asked = new Promise<void>((resolve) => (this.holding = resolve));
    if (message) this.answer(message);
  }

  /** Answers the older-history read held back. */
  releaseOlder(): void {
    const message = this.heldOlder;
    this.heldOlder = undefined;
    this.askedOlder = new Promise<void>((resolve) => (this.holdingOlder = resolve));
    if (message) this.answer(message);
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: this.status.get(sessionId) ?? "idle",
      turnCount: 1,
      updatedAt: START,
      ...(this.listedQueue.has(sessionId) ? { queue: this.listedQueue.get(sessionId) } : {}),
    };
  }

  /** The page this attach of `sessionId` answers: the visits in order, then the last one again. */
  private page(sessionId: string): Page {
    const pages = this.pages.get(sessionId) ?? [{ events: [] }];
    const visit = this.attached.get(sessionId) ?? 0;
    this.attached.set(sessionId, visit + 1);
    return pages[Math.min(visit, pages.length - 1)];
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/detach" && this.refuseDetach) {
      this.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: "no such session" } }),
      });
      return;
    }
    if (message.method === "_acpmux/attach" && sessionId === this.fail) {
      this.fail = undefined;
      this.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "unavailable" } }),
      });
      return;
    }
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch")
      result = { sessions: [this.summary(this.sessionA), this.summary(this.sessionB)] };
    else if (message.method === "_acpmux/attach") {
      const page = this.page(sessionId);
      const records = events(sessionId, page);
      result = {
        session: { ...this.summary(sessionId), ...(page.queue ? { queue: page.queue } : {}) },
        lastSeq: records.at(-1)?.seq ?? 0,
        events: records,
        hasMore: page.hasMore === true,
      };
    } else if (message.method === "_acpmux/events") {
      const older = message.params?.beforeSeq !== undefined ? this.older.get(sessionId) : undefined;
      const records = older ? events(sessionId, older) : [];
      result = { events: records, hasMore: older?.hasMore === true, lastSeq: records.at(-1)?.seq ?? 0 };
    }
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/** A client on `daemon`, selected on its chat A, and every snapshot it draws. */
const paneOn = async (daemon: Daemon) => {
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://cached.invalid/",
      token: "t",
      sessionId: daemon.sessionA,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  return { client, drawn, last: () => drawn.at(-1)! };
};

const text = (snapshot: AcpmuxSnapshot) =>
  snapshot.rows
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

test("the frame a switch back lands on draws the chat, before its attach answers", async () => {
  const daemon = new Daemon("frame-back");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at the retry path"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, drawn, last } = await paneOn(daemon);
  try {
    await client.select(B);
    expect(text(last())).toContain("Docs updated.");
    // Chat A again, with acpmux slow to answer its attach.
    daemon.hold = A;
    const back = client.select(A);
    await daemon.asked;
    // Drawn from the tail A's visit left, with A's attach still in flight.
    expect(text(last())).toContain("Retry added.");
    expect(last().sessionId).toBe(A);
    const beforeAttach = drawn.length;
    daemon.release();
    await back;
    expect(text(last())).toContain("Retry added.");
    expect(drawn.length).toBeGreaterThan(beforeAttach);
  } finally {
    client.close();
  }
});

test("a chat that ran on past one attach page comes back without a hole in its transcript", async () => {
  const daemon = new Daemon("gap");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  const tail: Step[] = [prompt("Turn one"), TURN_STARTED, reply(A, "Turn one done."), TURN_DONE];
  daemon.pages.set(A, [
    { events: tail },
    // While the reader was away the chat ran on, and acpmux's page starts far past the kept tail.
    {
      events: [prompt("Turn ninety"), TURN_STARTED, reply(A, "Turn ninety done."), TURN_DONE],
      from: 900,
      hasMore: true,
    },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    await client.select(A);
    const seqs = client.sessionEvents().map((event) => event.seq);
    expect(seqs).toEqual([900, 901, 902, 903]);
    expect(text(last())).toContain("Turn ninety done.");
    expect(text(last())).not.toContain("Turn one done.");
    // The transcript starts at the page, so its older history is still offered.
    expect(last().canLoadOlder).toBe(true);
  } finally {
    client.close();
  }
});

test("an older-history read in flight when the tail is dropped does not put the hole back", async () => {
  const daemon = new Daemon("older-in-flight");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [
    // The reader's visit starts mid-transcript, so the transcript offers older history.
    { events: [prompt("Turn ten"), TURN_STARTED, reply(A, "Turn ten done."), TURN_DONE], from: 10, hasMore: true },
    {
      events: [prompt("Turn ninety"), TURN_STARTED, reply(A, "Turn ninety done."), TURN_DONE],
      from: 900,
      hasMore: true,
    },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  daemon.older.set(A, { events: [prompt("Turn nine"), TURN_STARTED, reply(A, "Turn nine done."), TURN_DONE], from: 6 });
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    daemon.hold = A;
    daemon.holdOlder = A;
    const back = client.select(A);
    await daemon.asked;
    // The transcript asks for older history off the kept tail while the attach is still out.
    const older = client.loadOlder();
    await daemon.askedOlder;
    // The attach answers with a page far past the tail, so the tail goes.
    daemon.release();
    await back;
    // Only then does the older read land: it belongs to the transcript that just went.
    daemon.releaseOlder();
    await older;
    expect(client.sessionEvents().map((event) => event.seq)).toEqual([900, 901, 902, 903]);
    expect(text(last())).not.toContain("Turn nine done.");
    expect(text(last())).not.toContain("Turn ten done.");
  } finally {
    client.close();
  }
});

test("a chat that did not move keeps the history its visit had loaded", async () => {
  const daemon = new Daemon("kept-history");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  const tail: Step[] = [prompt("Turn one"), TURN_STARTED, reply(A, "Turn one done."), TURN_DONE];
  daemon.pages.set(A, [
    { events: tail },
    // acpmux answers the same chat again, as the page it holds (its newest records).
    { events: tail.slice(-2), from: 3 },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client } = await paneOn(daemon);
  try {
    await client.select(B);
    await client.select(A);
    expect(client.sessionEvents().map((event) => event.seq)).toEqual([1, 2, 3, 4]);
  } finally {
    client.close();
  }
});

test("an ask answered while away does not come back as a card", async () => {
  const daemon = new Daemon("ask-answered");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [
    { events: [prompt("Edit it"), TURN_STARTED, ASKING] },
    // It was allowed from somewhere else meanwhile, so acpmux's page carries the decision.
    {
      events: [
        prompt("Edit it"),
        TURN_STARTED,
        ASKING,
        ["mux", "permission_decision", { permissionId: "p1", optionId: "allow" }],
        TURN_DONE,
      ],
    },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    expect(last().permission?.permissionId).toBe("p1");
    await client.select(B);
    daemon.hold = A;
    const back = client.select(A);
    await daemon.asked;
    // The frame back: the chat is drawn, and nothing is waiting for an answer.
    expect(text(last())).toContain("Edit it");
    expect(last().permission).toBeUndefined();
    daemon.release();
    await back;
    expect(last().permission).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a turn that ended while away does not come back as a running turn", async () => {
  const daemon = new Daemon("turn-ended");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [
    { events: [prompt("Run it"), TURN_STARTED, reply(A, "Running.")] },
    { events: [prompt("Run it"), TURN_STARTED, reply(A, "Running."), TURN_DONE] },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  daemon.status.set(A, "running");
  const { client, last } = await paneOn(daemon);
  try {
    expect(last().isWorking).toBe(true);
    await client.select(B);
    // The turn finished while the reader was away: acpmux says so in its session list.
    daemon.status.set(A, "idle");
    daemon.changed(A);
    daemon.hold = A;
    const back = client.select(A);
    await daemon.asked;
    expect(text(last())).toContain("Running.");
    expect(last().isWorking).toBe(false);
    daemon.release();
    await back;
    expect(last().isWorking).toBe(false);
  } finally {
    client.close();
  }
});

test("a chat still running when the reader comes back draws as working at once", async () => {
  const daemon = new Daemon("still-running");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Run it"), TURN_STARTED, reply(A, "Running.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  daemon.status.set(A, "running");
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    daemon.hold = A;
    const back = client.select(A);
    await daemon.asked;
    expect(last().isWorking).toBe(true);
    daemon.release();
    await back;
  } finally {
    client.close();
  }
});

test("a queued prompt keeps its whole text on the frame back", async () => {
  const daemon = new Daemon("queued-text");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  const whole = `Rewrite the uploader's retry path ${"and the tests that cover it ".repeat(8)}`;
  daemon.pages.set(A, [
    {
      events: [prompt("Edit it"), ["mux", "queued", { promptId: "q1", text: whole }]],
      queue: [{ promptId: "q1", prompt: whole }],
    },
  ]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  // acpmux's session list carries only a preview of a queued prompt.
  daemon.listedQueue.set(A, [{ promptId: "q1", prompt: `${whole.slice(0, 40)}…` }]);
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    daemon.hold = A;
    const back = client.select(A);
    await daemon.asked;
    expect(last().queue.map((entry) => entry.prompt)).toEqual([whole]);
    daemon.release();
    await back;
  } finally {
    client.close();
  }
});

test("a refused detach of the chat being left does not stop the chat being opened", async () => {
  const daemon = new Daemon("detach-refused");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at it"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    // acpmux no longer resolves the chat being left (it was archived from elsewhere).
    daemon.refuseDetach = true;
    expect(await client.select(A)).toBe(A);
    expect(text(last())).toContain("Retry added.");
  } finally {
    client.close();
  }
});

/** Lets every queued microtask (the stand-in daemon's replies, the client's awaits on them) run. */
const drain = async () => {
  for (let turn = 0; turn < 20; turn += 1) await new Promise<void>((resolve) => queueMicrotask(resolve));
};

test("a switch attaches the next chat without waiting for the detach of the chat left", async () => {
  const daemon = new Daemon("detach-parallel");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at it"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    // acpmux is slow to answer the detach of the chat being left: the next chat opens anyway (on
    // the base the select waited for that reply and this await never returned).
    daemon.holdDetach = A;
    expect(await client.select(B)).toBe(B);
    expect(text(last())).toContain("Docs updated.");
    const order = daemon.sent.map((message) => `${message.method} ${String(message.params?.sessionId ?? "")}`);
    expect(order.indexOf(`_acpmux/attach ${B}`)).toBeGreaterThan(order.indexOf(`_acpmux/detach ${A}`));
    daemon.releaseDetach();
  } finally {
    client.close();
  }
});

test("a switch straight back waits for that chat's own detach before attaching it", async () => {
  const daemon = new Daemon("detach-back");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at it"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    daemon.holdDetach = A;
    await client.select(B);
    const attachesOfA = () =>
      daemon.sent.filter((message) => message.method === "_acpmux/attach" && message.params?.sessionId === A).length;
    const before = attachesOfA();
    // Back to A while its detach is still out: an attach sent now could be answered before the
    // detach and lose its subscription, so it waits for the detach's reply.
    let settled = false;
    const back = client.select(A).finally(() => (settled = true));
    await drain();
    expect(settled).toBe(false);
    expect(attachesOfA()).toBe(before);
    daemon.releaseDetach();
    expect(await back).toBe(A);
    expect(attachesOfA()).toBe(before + 1);
    expect(text(last())).toContain("Retry added.");
  } finally {
    client.close();
  }
});

test("switching away from a chat twice before its detaches answer attaches it after both, in any order", async () => {
  const daemon = new Daemon("detach-rapid");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at it"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    const attachesOfA = () =>
      daemon.sent.filter((message) => message.method === "_acpmux/attach" && message.params?.sessionId === A).length;
    daemon.holdDetach = A;
    // A -> B -> A -> B -> A, every detach of A still out.
    await client.select(B);
    const before = attachesOfA();
    const first = client.select(A);
    expect(await client.select(B)).toBe(B);
    let settled = false;
    const back = client.select(A).finally(() => (settled = true));
    await drain();
    expect(attachesOfA()).toBe(before);
    // The second detach answers first: the last switch still waits for the first one, which acpmux
    // could otherwise answer after its attach and so drop the chat's new subscription.
    daemon.releaseDetach("newest");
    await drain();
    expect(settled).toBe(false);
    expect(attachesOfA()).toBe(before);
    daemon.releaseDetach();
    // The switch the first detach held was superseded and attached nothing.
    expect(await first).toBeUndefined();
    expect(await back).toBe(A);
    expect(attachesOfA()).toBe(before + 1);
    const order = daemon.sent.map((message) => `${message.method} ${String(message.params?.sessionId ?? "")}`);
    expect(order.lastIndexOf(`_acpmux/attach ${A}`)).toBeGreaterThan(order.lastIndexOf(`_acpmux/detach ${A}`));
    expect(text(last())).toContain("Retry added.");
  } finally {
    client.close();
  }
});

test("a chat whose attach fails does not stay on screen as if it had been read", async () => {
  const daemon = new Daemon("attach-failed");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [{ events: [prompt("Look at it"), reply(A, "Retry added.")] }]);
  daemon.pages.set(B, [{ events: [prompt("Docs"), reply(B, "Docs updated.")] }]);
  const { client, last } = await paneOn(daemon);
  try {
    await client.select(B);
    daemon.fail = A;
    await expect(client.select(A)).rejects.toThrow();
    expect(text(last())).not.toContain("Retry added.");
    expect(client.sessionEvents()).toEqual([]);
  } finally {
    client.close();
  }
});
