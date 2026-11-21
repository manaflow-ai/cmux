// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Every Fork To destination opens the fork the same way on the page's side (Leo, 2026-11-07: "our
// forking behavior, it's nice and it doesn't tear the screen and it loads fast and it goes as
// people would expect forking chats should go"). #37380 made a fork's own tab draw the fork on the
// frame it opens (forkTail.ts); the app opens that tab at any of ten places (AgentForkDestination),
// and each must get the same hand-over. Per destination, these hold the page to it:
//
//   - the forking page hands the host the fork's rows before it asks for the tab (`chat.tail`
//     reaches the host before `chat.openTab`), and asks for that destination, once;
//   - the forking page stays on the chat it forked, and does not take the keyboard from the fork;
//   - the fork's page draws the fork from those rows before its attach answers, ending at the
//     fork point (the record it forked through, not the chat's newest), each row once after.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { openFork, openInOwnTab } from "../src/agent-session/acpmux/conversation/openFork";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 7, 9, 0, 0);
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

type Message = { id?: number; method: string; params?: Record<string, unknown> };
type Step = [dir: string, kind: string, msg: Record<string, unknown>, seq?: number];
type Page = { events: Step[]; from?: number; at?: number };

const events = (sessionId: string, page: Page) =>
  page.events.map(([dir, kind, msg, at], index) => {
    const seq = at ?? (page.from ?? 1) + index;
    return { sessionId, seq, at: (page.at ?? START) + seq * 1000, dir, kind, msg };
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

const PARENT = "fork-parent";
const FORK = "fork-child";
const FORK_CREATED = START + 60_000;

/// acpmux for a chat and its fork, answering the pages the fixture holds and the fork with `fork`.
/// `hold` keeps the next attach of a chat unanswered, until `release`.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  private held?: Message;
  private holding?: () => void;
  asked = new Promise<void>((resolve) => (this.holding = resolve));

  constructor(
    readonly pages: Map<string, Page>,
    readonly fork: Record<string, unknown>,
  ) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    if (message.method === "_acpmux/attach" && message.params?.sessionId === this.hold) {
      this.held = message;
      this.hold = undefined;
      this.holding?.();
      return;
    }
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  release(): void {
    const message = this.held;
    this.held = undefined;
    if (message) this.answer(message);
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      createdAt: sessionId === FORK ? FORK_CREATED : START,
      ...(sessionId === FORK ? { parentId: PARENT, forkSeq: this.fork.forkSeq } : {}),
    };
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: ["acp.session.fork"] } },
      };
    else if (message.method === "_acpmux/watch") result = { sessions: [this.summary(PARENT), this.summary(FORK)] };
    else if (message.method === "acp.session.fork")
      // As acpmux answers it (server/requests.rs `SESSION_FORK`): the fork's summary in `_meta`.
      result = {
        sessionId: FORK,
        modes: null,
        configOptions: [],
        _meta: { acpmux: { ...this.summary(FORK), ...this.fork } },
      };
    else if (message.method === "_acpmux/attach") {
      const records = events(sessionId, this.pages.get(sessionId) ?? { events: [] });
      result = { session: this.summary(sessionId), lastSeq: records.at(-1)?.seq ?? 0, events: records, hasMore: false };
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/// The app host's tail store, as ``AgentPaneTailCache`` holds it.
class Host {
  readonly tails = new Map<string, any>();
  /// Each `chat.openTab`, with whether the host held the fork's tail when it came.
  readonly opened: { sessionId: string; placement: string; tailHeld: boolean }[] = [];
  install(): void {
    (
      dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
    ).cmuxAcpmuxActions = {
      "chat.tail.get": async (params: any) => this.tails.get(String(params.sessionId)) ?? null,
      "chat.tail": async (params: any) => {
        this.tails.set(String(params.sessionId), params.tail);
        return null;
      },
      "chat.openTab": async (params: any) => {
        const sessionId = String(params.sessionId);
        this.opened.push({ sessionId, placement: String(params.placement), tailHeld: this.tails.has(sessionId) });
        return null;
      },
    };
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const text = (snapshot: AcpmuxSnapshot | undefined) =>
  (snapshot?.rows ?? [])
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

function page(pages: Map<string, Page>, fork: Record<string, unknown>, sessionId: string, hold = false) {
  const daemon = new Daemon(pages, fork);
  if (hold) daemon.hold = sessionId;
  const drawn: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://fork.invalid/", token: "t", sessionId },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  return { daemon, drawn, client, last: () => drawn.at(-1) };
}

const PARENT_HISTORY: Step[] = [
  prompt("Look at the retry path"),
  reply(PARENT, "Retry added."),
  prompt("And tests"),
  reply(PARENT, "Tests added."),
];

const PLACEMENTS = [
  "right",
  "left",
  "up",
  "down",
  "columnRight",
  "columnLeft",
  "row",
  "tab",
  "workspace",
  "window",
] as const;

for (const placement of PLACEMENTS) {
  test(`a fork to ${placement} opens drawn from the chat it forked, at the fork point`, async () => {
    const host = new Host();
    host.install();
    // The fork branches after the first turn's reply (seq 2), not at the chat's newest record:
    // acpmux's fork by reference shows the chat's records through it, then its own.
    const pages = new Map<string, Page>([
      [PARENT, { events: PARENT_HISTORY }],
      [FORK, { events: [...PARENT_HISTORY.slice(0, 2), ["mux", "forked", { from: PARENT }, 3]] }],
    ]);
    const fork = { sessionId: FORK, createdAt: FORK_CREATED, lastSeq: 3, forkSeq: 2, parentId: PARENT };

    const forking = page(pages, fork, PARENT);
    const client = await forking.client;
    live.push(client);
    await flush();
    let focused = 0;
    const forked = await client.fork(2, undefined, true);
    const opened = await openFork(forked, PARENT, placement, {
      open: (session, where) =>
        openInOwnTab(client, (method, params) => (window as any).cmuxAcpmuxActions[method](params), session, where),
      selected: () => client.selectedSession,
      select: (id) => client.select(id),
      persist: async () => undefined,
      focus: () => (focused += 1),
    });
    await flush();
    expect(opened).toBe(FORK);
    expect(host.opened).toEqual([{ sessionId: FORK, placement, tailHeld: true }]);
    expect(host.tails.get(FORK)?.forkedThrough).toBe(2);
    // The forking page keeps its chat, and the keyboard goes to the fork's tab, not here.
    expect(client.selectedSession).toBe(PARENT);
    expect(focused).toBe(0);

    resetKeptTailsForTests();
    const tab = page(pages, fork, FORK, true);
    await tab.daemon.asked;
    await flush();
    const first = tab.last()!;
    expect(first.sessionId).toBe(FORK);
    expect(first.drewKeptTail).toBe(true);
    // At the fork point: the first turn's reply is its newest row; the chat's later turn is not the fork's.
    expect(text(first)).toContain("Retry added.");
    expect(text(first)).not.toContain("Tests added.");
    tab.daemon.release();
    live.push(await tab.client);
    await flush();
    const shown = text(tab.last());
    expect(shown.split("Retry added.").length - 1).toBe(1);
    expect(shown).not.toContain("Tests added.");
  });
}
