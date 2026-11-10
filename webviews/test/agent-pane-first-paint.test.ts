// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Leo, 2026-11-01: "the loading for everything is just slow end to end / loading into a chat and
// some of its recent messages, loading the various ui elements of the metadata, etc. it's not
// cached well enough nor prerendered/prefetched well enough". A chat opened cold drew nothing
// until three side reads were in as well as its attach page: its permission groups, its handoff
// and (from an older acpmux) the opener of the turn the page starts inside. And whatever drew
// before the attach (the switch's hold running out on a slow daemon) showed no title, harness or
// model, though the chat list had them. These hold the client to:
//
//   - the rows draw when the attach answers, with the permission and handoff reads still out,
//     and each read fills in when it lands;
//   - an older acpmux's chat waits for its turn opener's read only, never the side reads, and
//     draws the opener above its rows on the first frame (agent-pane-restore-long-turn);
//   - a frame drawn before the attach shows the chat's listed title, harness and model.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { HANDOFF_OPS } from "../src/agent-session/acpmux/handoff/protocol";
import { PERMISSION_GROUP_OPS } from "../src/agent-session/acpmux/permissions/protocol";
import { askOnSingleCard } from "../src/agent-session/acpmux/permissionKeys";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 1, 9, 0, 0);
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

type Message = { id?: number; method: string; params?: Record<string, any> };
type Step = [dir: string, kind: string, msg: Record<string, unknown>];

const prompt = (text: string): Step => ["mux", "user_message", { text }];
const reply = (sessionId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];

/** A pending permission group of `sessionId`, as `_acpmux/permission_groups` answers it. */
const groups = (sessionId: string) => ({
  groups: [
    {
      groupId: `group-${sessionId}`,
      sessionId,
      turnId: null,
      revision: 1,
      state: "pending",
      items: [{ permissionId: `perm-${sessionId}`, request: { title: "Edit upload.sh" }, state: "pending" }],
      decisions: ["allow_once", "allow_chat", "deny"],
      decision: null,
    },
  ],
  chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
  coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
  batching: { windowMs: 50, maxItems: 8, maxPendingGroups: 4, maxReceipts: 8 },
});

/**
 * acpmux for two chats that serves permission groups and handoffs. `holding` keeps every request
 * a predicate picks unanswered until `release` answers them.
 */
class Daemon {
  readonly sessionA: string;
  readonly sessionB: string;
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];
  /// Each chat's attach page: its records from seq `from`, and whether older ones exist.
  readonly pages = new Map<string, { steps: Step[]; from?: number; hasMore?: boolean }>();
  /// Older acpmux: the attach names no turn opener (`turnOpener` absent from the reply).
  servesOpener = true;
  origin = "local";
  status = { peers: [{ name: "remote-box", connected: true }] };
  /// The turn opener's own read answers these records of the chat.
  readonly prompts = new Map<string, Step[]>();
  /// Asks the attach lists as still pending, per chat (`detail.pending`).
  readonly pending = new Map<string, Record<string, unknown>[]>();
  holding?: (message: Message) => boolean;
  private held: Message[] = [];

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
    if (this.holding?.(message)) {
      this.held.push(message);
      return;
    }
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  /** Answers every held request a predicate picks (all of them by default). */
  release(which: (message: Message) => boolean = () => true): void {
    const out = this.held.filter(which);
    this.held = this.held.filter((message) => !which(message));
    for (const message of out) this.answer(message);
  }

  heldMethods(): string[] {
    return this.held.map((message) => message.method);
  }

  summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/uploader",
      title: `Chat ${sessionId}`,
      harness: "codex",
      family: "codex",
      model: "gpt-6.1-sol",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
    };
  }

  private records(sessionId: string, steps: Step[], from = 1) {
    return steps.map(([dir, kind, msg], at) => {
      const seq = from + at;
      return { sessionId, seq, at: START + seq * 1000, dir, kind, msg };
    });
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = null;
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: {
          acpmux: {
            origin: this.origin,
            extensions: [],
            operations: [...Object.values(PERMISSION_GROUP_OPS), ...Object.values(HANDOFF_OPS)],
          },
        },
      };
    else if (message.method === "_acpmux/status") result = this.status;
    else if (message.method === "_acpmux/watch")
      result = { sessions: [this.summary(this.sessionA), this.summary(this.sessionB)] };
    else if (message.method === "_acpmux/attach") {
      const page = this.pages.get(sessionId) ?? { steps: [] };
      const events = this.records(sessionId, page.steps, page.from);
      result = {
        session: {
          ...this.summary(sessionId),
          ...(this.pending.has(sessionId) ? { pending: this.pending.get(sessionId) } : {}),
        },
        lastSeq: events.at(-1)?.seq ?? 0,
        events,
        hasMore: page.hasMore === true,
        ...(this.servesOpener ? { turnOpener: null } : {}),
      };
    } else if (message.method === "_acpmux/events") {
      const events =
        Array.isArray(message.params?.kinds) && message.params.kinds.includes("user_message")
          ? this.records(sessionId, this.prompts.get(sessionId) ?? [])
          : [];
      result = { events, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    } else if (message.method === PERMISSION_GROUP_OPS.groups) result = groups(sessionId);
    else if (message.method === HANDOFF_OPS.get) result = null;
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/** A client on `daemon`, selected on its chat A, and every snapshot it draws. */
const paneOn = async (daemon: Daemon) => {
  const drawn: AcpmuxSnapshot[] = [];
  const waiting: { where: (snapshot: AcpmuxSnapshot) => boolean; resolve: (snapshot: AcpmuxSnapshot) => void }[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://first-paint.invalid/",
      token: "t",
      sessionId: daemon.sessionA,
    },
    (snapshot) => {
      if (snapshot.type !== "snapshot") return;
      drawn.push(snapshot);
      for (const waiter of waiting.splice(0))
        if (waiter.where(snapshot)) waiter.resolve(snapshot);
        else waiting.push(waiter);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  /** The next snapshot drawn that `where` picks. */
  const drawnWhere = (where: (snapshot: AcpmuxSnapshot) => boolean) =>
    new Promise<AcpmuxSnapshot>((resolve) => waiting.push({ where, resolve }));
  return { client, drawn, drawnWhere, last: () => drawn.at(-1)! };
};

const text = (snapshot: AcpmuxSnapshot) =>
  snapshot.rows
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

const turns = async (count = 20) => {
  for (let at = 0; at < count; at += 1) await new Promise<void>((resolve) => setTimeout(resolve, 0));
};

/** Whether `promise` settles within `ms`. */
const settlesWithin = (promise: Promise<unknown>, ms: number) =>
  Promise.race([
    promise.then(
      () => true,
      () => true,
    ),
    // fixed-wait: a deadline, not a wait: the pass settles as soon as the select does, and only a
    // select still waiting on the held reads (the base this fixes) runs into it.
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), ms)),
  ]);

const sideRead = (message: Message) =>
  message.method === PERMISSION_GROUP_OPS.groups || message.method === HANDOFF_OPS.get;

test("a cold tail draws before the full prompt index is read, then fills its labels after paint", async () => {
  const daemon = new Daemon("index-after-paint");
  const A = daemon.sessionA;
  daemon.pages.set(A, { steps: [prompt("Latest"), reply(A, "Tail ready.")], from: 101, hasMore: true });
  daemon.prompts.set(A, [prompt("Earlier")]);
  const frames = new Map<number, FrameRequestCallback>();
  let frameId = 0;
  const savedFrame = scope.requestAnimationFrame;
  const savedCancel = scope.cancelAnimationFrame;
  const visibility = Object.getOwnPropertyDescriptor(dom.window.document, "visibilityState");
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, value: "visible" });
  scope.requestAnimationFrame = (callback: FrameRequestCallback) => {
    frames.set(++frameId, callback);
    return frameId;
  };
  scope.cancelAnimationFrame = (id: number) => frames.delete(id);
  const { client, last } = await paneOn(daemon);
  const indexReads = () => daemon.sent.filter((message) => message.params?.promptIndex === true);
  try {
    expect(text(last())).toContain("Tail ready.");
    expect(indexReads()).toHaveLength(0);
    expect(last().promptCount).toBe(1);
    const due = Array.from(frames.values());
    frames.clear();
    for (const callback of due) {
      callback(performance.now());
    }
    // rAF still precedes the frame: even an immediate daemon must not parse history here.
    expect(indexReads()).toHaveLength(0);
    await turns();
    expect(indexReads()).toHaveLength(1);
    expect(last().earlierPrompts?.map((row) => row.text)).toEqual(["Earlier"]);
    expect(text(last())).toContain("Tail ready.");
  } finally {
    client.close();
    scope.requestAnimationFrame = savedFrame;
    scope.cancelAnimationFrame = savedCancel;
    if (visibility) Object.defineProperty(dom.window.document, "visibilityState", visibility);
    else Reflect.deleteProperty(dom.window.document, "visibilityState");
  }
});

test("a hidden tail starts no whole-history read, and closing cancels its deferred read", async () => {
  const daemon = new Daemon("hidden-index");
  const A = daemon.sessionA;
  daemon.pages.set(A, { steps: [prompt("Latest"), reply(A, "Tail ready.")], from: 101, hasMore: true });
  const visibility = Object.getOwnPropertyDescriptor(dom.window.document, "visibilityState");
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, value: "hidden" });
  const { client, last } = await paneOn(daemon);
  try {
    expect(text(last())).toContain("Tail ready.");
    await turns();
    expect(daemon.sent.some((message) => message.params?.promptIndex === true)).toBe(false);
    client.close();
    Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, value: "visible" });
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    await turns();
    expect(daemon.sent.some((message) => message.params?.promptIndex === true)).toBe(false);
  } finally {
    client.close();
    if (visibility) Object.defineProperty(dom.window.document, "visibilityState", visibility);
    else Reflect.deleteProperty(dom.window.document, "visibilityState");
  }
});

test("a cold switch draws the chat's rows with its permission and handoff reads still out", async () => {
  const daemon = new Daemon("side-reads");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, { steps: [prompt("Retry path"), reply(A, "Retry added.")] });
  daemon.pages.set(B, { steps: [prompt("Docs"), reply(B, "Docs updated.")] });
  const { client, last } = await paneOn(daemon);
  try {
    // B's permission groups and handoff stay unanswered, as on a busy daemon.
    daemon.holding = (message) => sideRead(message) && message.params?.sessionId === B;
    const switched = client.select(B);
    expect(await settlesWithin(switched, 1_000)).toBe(true);
    expect(await switched).toBe(B);
    expect(last().sessionId).toBe(B);
    expect(text(last())).toContain("Docs updated.");
    expect(daemon.heldMethods().sort()).toEqual([HANDOFF_OPS.get, PERMISSION_GROUP_OPS.groups].sort());
    // Nothing of B's asks drawn yet; its group lands once the read answers.
    expect(last().permissionGroups?.groups ?? []).toEqual([]);
    daemon.release();
    await turns();
    expect(last().permissionGroups?.ready).toBe(true);
    expect(last().permissionGroups?.groups.map((group) => group.groupId)).toEqual([`group-${B}`]);
    // The rows stay drawn under it.
    expect(text(last())).toContain("Docs updated.");
  } finally {
    client.close();
  }
});

test("an older acpmux's chat draws with its turn opener once that read alone answers", async () => {
  const daemon = new Daemon("opener-only");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.servesOpener = false;
  daemon.pages.set(A, { steps: [prompt("Retry path"), reply(A, "Retry added.")] });
  // B's page starts inside a long turn: its prompt is at seq 1, the page at seq 40.
  daemon.pages.set(B, { steps: [reply(B, "Still porting the parser.")], from: 40, hasMore: true });
  daemon.prompts.set(B, [prompt("Port the parser")]);
  const { client, last } = await paneOn(daemon);
  try {
    const openerRead = (message: Message) =>
      message.method === "_acpmux/events" &&
      message.params?.sessionId === B &&
      // The rail's prompt index reads `user_message` records too (direct.ts readPromptIndex).
      message.params?.promptIndex !== true &&
      Array.isArray(message.params?.kinds) &&
      message.params.kinds.includes("user_message");
    // B's opener read and its side reads are all out; only the opener's answers.
    daemon.holding = (message) => message.params?.sessionId === B && (openerRead(message) || sideRead(message));
    const switched = client.select(B);
    await turns();
    expect(daemon.heldMethods()).toContain("_acpmux/events");
    daemon.release(openerRead);
    expect(await settlesWithin(switched, 1_000)).toBe(true);
    // The first frame of B holds its opener above its rows.
    const shown = text(last());
    expect(shown).toContain("Still porting the parser.");
    expect(shown.indexOf("Port the parser")).toBeGreaterThanOrEqual(0);
    expect(shown.indexOf("Port the parser")).toBeLessThan(shown.indexOf("Still porting the parser."));
    expect(daemon.heldMethods().sort()).toEqual([HANDOFF_OPS.get, PERMISSION_GROUP_OPS.groups].sort());
    daemon.release();
  } finally {
    client.close();
  }
});

test("a frame drawn before a slow attach shows the chat's listed title, harness and model", async () => {
  const daemon = new Daemon("listed-header");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, { steps: [prompt("Retry path"), reply(A, "Retry added.")] });
  daemon.pages.set(B, { steps: [prompt("Docs"), reply(B, "Docs updated.")] });
  const { client, drawnWhere, last } = await paneOn(daemon);
  try {
    daemon.holding = (message) => message.method === "_acpmux/attach" && message.params?.sessionId === B;
    // The switch's hold (SWITCH_HOLD_MS, 1.5 s) runs out with B's attach still out: the frame it
    // draws then is B's.
    const drawnFirst = drawnWhere((snapshot) => snapshot.sessionId === B);
    const switched = client.select(B);
    const shown = await drawnFirst;
    expect(daemon.heldMethods()).toEqual(["_acpmux/attach"]);
    expect(shown.sessionId).toBe(B);
    expect(shown.summary?.title).toBe(`Chat ${B}`);
    expect(shown.summary?.harness).toBe("codex");
    expect(shown.summary?.model).toBe("gpt-6.1-sol");
    expect(shown.summary?.cwd).toBe("/home/dev/uploader");
    daemon.release();
    await switched;
    expect(text(last())).toContain("Docs updated.");
    expect(last().summary?.title).toBe(`Chat ${B}`);
  } finally {
    client.close();
  }
});

// Leo ask-5470c36d23: "EVERYTHING IS JUST SO DELAYED". A local chat's attach and
// rows do not depend on another machine's status. The release timer simulates one slow
// status reply in the same harness on base and head; the assertion is ordering, not a
// machine-dependent timing budget. This measures client snapshot readiness, not pixels.
test("a local chat draws before a slow peer-status reply and learns peers when it arrives", async () => {
  const daemon = new Daemon("slow-peer-status");
  daemon.pages.set(daemon.sessionA, {
    steps: [prompt("Local work"), reply(daemon.sessionA, "Ready without peer status.")],
  });
  daemon.holding = (message) => message.method === "_acpmux/status";
  const started = performance.now();
  let released = false;
  // fixed-wait: simulated daemon latency; cleared as soon as the run ends.
  const timer = setTimeout(() => {
    released = true;
    daemon.release();
  }, 250);
  const opening = paneOn(daemon);
  try {
    const { client, last } = await opening;
    try {
      console.log(`CHAT_STATUS_OPEN_MS=${(performance.now() - started).toFixed(1)}`);
      const beforeStatus = !released;
      const shown = text(last());
      daemon.release();
      await turns();
      expect(last().peers).toContain("remote-box");
      expect(shown).toContain("Ready without peer status.");
      expect(beforeStatus).toBe(true);
    } finally {
      client.close();
    }
  } finally {
    clearTimeout(timer);
    daemon.release();
    (await opening).client.close();
  }
});

test("a remote connection still settles peer status before completing its open", async () => {
  const daemon = new Daemon("remote-peer-status");
  daemon.origin = "remote";
  daemon.pages.set(daemon.sessionA, { steps: [prompt("Remote work"), reply(daemon.sessionA, "Ready.")] });
  daemon.holding = (message) => message.method === "_acpmux/status";
  const opening = paneOn(daemon);
  try {
    expect(await settlesWithin(opening, 100)).toBe(false);
    expect(daemon.heldMethods()).toContain("_acpmux/status");
    daemon.release();
    const { last } = await opening;
    expect(last().peers).toContain("remote-box");
    expect(text(last())).toContain("Ready.");
  } finally {
    daemon.release();
    (await opening).client.close();
  }
});

test("a grouped ask draws on the card at once while its group read is out, then the group takes it", async () => {
  // Leo, 2026-11-03, on a peer chat's Run command card: "it needed to load the permissions
  // settings/the permissions pop itself for like 10 seconds before it loaded". The ask waited, undrawn,
  // for `_acpmux/permission_groups`, which on a peer waits on its attach and the shared read queue.
  const daemon = new Daemon("grouped-ask");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, { steps: [prompt("Retry path"), reply(A, "Retry added.")] });
  daemon.pages.set(B, { steps: [prompt("Check disk"), reply(B, "Running du.")] });
  daemon.pending.set(B, [
    {
      permissionId: `perm-${B}`,
      groupId: `group-${B}`,
      request: {
        toolCall: { toolCallId: "t1", title: "Run du -sh .", kind: "execute", rawInput: { command: "du -sh ." } },
        options: [
          { optionId: "allow", name: "Allow once", kind: "allow_once" },
          { optionId: "deny", name: "Deny", kind: "reject_once" },
        ],
      },
    },
  ]);
  const { client, last } = await paneOn(daemon);
  try {
    daemon.holding = (message) => message.method === PERMISSION_GROUP_OPS.groups && message.params?.sessionId === B;
    expect(await settlesWithin(client.select(B), 1_000)).toBe(true);
    await turns();
    expect(daemon.heldMethods()).toEqual([PERMISSION_GROUP_OPS.groups]);
    // The first frame of B has its ask on the card the pane draws, with the group read still out.
    expect(last().permission?.permissionId).toBe(`perm-${B}`);
    expect(askOnSingleCard(last().permission, last().permissionGroups)).toBe(true);
    daemon.release();
    await turns();
    // The read landed: the group's card holds the ask, and no single card repeats it.
    expect(last().permissionGroups?.groups.map((group) => group.groupId)).toEqual([`group-${B}`]);
    expect(askOnSingleCard(last().permission, last().permissionGroups)).toBe(false);
    // Back to A, then B again: B's groups come back from its last read while the refresh is out, and
    // its ask is the group's card only, never a single card beside it.
    expect(await settlesWithin(client.select(A), 1_000)).toBe(true);
    await turns();
    expect(await settlesWithin(client.select(B), 1_000)).toBe(true);
    await turns();
    expect(daemon.heldMethods()).toEqual([PERMISSION_GROUP_OPS.groups]);
    expect(last().permissionGroups?.groups.map((group) => group.groupId)).toEqual([`group-${B}`]);
    expect(askOnSingleCard(last().permission, last().permissionGroups)).toBe(false);
    daemon.release();
    await turns();
    expect(askOnSingleCard(last().permission, last().permissionGroups)).toBe(false);
  } finally {
    client.close();
  }
});

test("a reopened chat's restored group keeps its ask, and an ungrouped ask behind it draws at once", async () => {
  // Codex review of #34386 (F2): on reopen the restored groups list the grouped ask while their
  // refresh is out; that ask headed the single card's queue, hidden as the panel's, and the ungrouped
  // ask behind it waited for the refresh.
  const daemon = new Daemon("restored-group-queue");
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, { steps: [prompt("Retry path"), reply(A, "Retry added.")] });
  daemon.pages.set(B, { steps: [prompt("Check disk"), reply(B, "Running du.")] });
  const ask = (permissionId: string, title: string, groupId?: string) => ({
    permissionId,
    ...(groupId ? { groupId } : {}),
    request: {
      toolCall: { toolCallId: permissionId, title, kind: "execute", rawInput: { command: title } },
      options: [
        { optionId: "allow", name: "Allow once", kind: "allow_once" },
        { optionId: "deny", name: "Deny", kind: "reject_once" },
      ],
    },
  });
  daemon.pending.set(B, [ask(`perm-${B}`, "du -sh .", `group-${B}`), ask(`perm2-${B}`, "ls")]);
  const { client, last } = await paneOn(daemon);
  try {
    expect(await settlesWithin(client.select(B), 1_000)).toBe(true);
    await turns();
    expect(last().permissionGroups?.groups.map((group) => group.groupId)).toEqual([`group-${B}`]);
    expect(await settlesWithin(client.select(A), 1_000)).toBe(true);
    await turns();
    daemon.holding = (message) => message.method === PERMISSION_GROUP_OPS.groups && message.params?.sessionId === B;
    expect(await settlesWithin(client.select(B), 1_000)).toBe(true);
    await turns();
    expect(daemon.heldMethods()).toEqual([PERMISSION_GROUP_OPS.groups]);
    // The restored group holds its ask; the ungrouped one is the single card, not hidden behind it.
    expect(last().permissionGroups?.groups.map((group) => group.groupId)).toEqual([`group-${B}`]);
    expect(last().permission?.permissionId).toBe(`perm2-${B}`);
    expect(askOnSingleCard(last().permission, last().permissionGroups)).toBe(true);
    daemon.release();
  } finally {
    client.close();
  }
});
