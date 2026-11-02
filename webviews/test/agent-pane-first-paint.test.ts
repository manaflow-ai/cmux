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

const START = Date.UTC(2026, 10, 1, 9, 0, 0);
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
  /// The turn opener's own read answers these records of the chat.
  readonly prompts = new Map<string, Step[]>();
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
            origin: "local",
            extensions: [],
            operations: [...Object.values(PERMISSION_GROUP_OPS), ...Object.values(HANDOFF_OPS)],
          },
        },
      };
    else if (message.method === "_acpmux/watch")
      result = { sessions: [this.summary(this.sessionA), this.summary(this.sessionB)] };
    else if (message.method === "_acpmux/attach") {
      const page = this.pages.get(sessionId) ?? { steps: [] };
      const events = this.records(sessionId, page.steps, page.from);
      result = {
        session: this.summary(sessionId),
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
