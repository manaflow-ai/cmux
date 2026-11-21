// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A fork opens at once in the tab it goes to (Leo, 2026-11-06: "just the fork does what you'd
// expect ... just make it fast and make it work well"). Fork Conversation opens the fork in a tab
// of its own, a new page that held nothing of it, so it read the fork cold and faded it in. The
// forking page holds the fork's history already, so it hands it to the app host as the fork's tail
// (forkTail.ts), and the fork's page draws it before its attach answers. These hold the page to it:
//
//   - a fork by reference (its log past the seq it branched at) is handed over, and its new tab
//     draws it before its attach answers, with each row once after;
//   - a fork that copied the history (its log renumbered, ending at the seq it branched at) is not;
//   - rows handed over that acpmux's own page of the fork does not hold record for record go, and
//     the page alone is the fork.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 6, 9, 0, 0);
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
  install(): void {
    (
      dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
    ).cmuxAcpmuxActions = {
      "chat.tail.get": async (params: any) => this.tails.get(String(params.sessionId)) ?? null,
      "chat.tail": async (params: any) => {
        this.tails.set(String(params.sessionId), params.tail);
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

/// Forks the parent on its own page, through its last record, staying on it (Fork Conversation),
/// and closes that page: the fork's tab is another.
async function forkParent(pages: Map<string, Page>, fork: Record<string, unknown>): Promise<string | undefined> {
  const forking = page(pages, fork, PARENT);
  const client = await forking.client;
  await flush();
  const id = await client.fork("live", undefined, true);
  await flush();
  client.close();
  return id;
}

test("a fork by reference opens in its new tab drawn from the chat it forked, before its attach answers", async () => {
  const host = new Host();
  host.install();
  const pages = new Map<string, Page>([
    [PARENT, { events: PARENT_HISTORY }],
    // acpmux's fork by reference: the chat's records at their own seqs, then the fork's own.
    [FORK, { events: [...PARENT_HISTORY, ["mux", "forked", { from: PARENT }, 7]] }],
  ]);
  // The fork branches past the page's newest record: `forkSeq` counts the chat's wire records
  // too (its turn's `response`), which no page is sent.
  const fork = { sessionId: FORK, createdAt: FORK_CREATED, lastSeq: 7, forkSeq: 6, parentId: PARENT };
  expect(await forkParent(pages, fork)).toBe(FORK);
  expect(host.tails.get(FORK)?.forkedThrough).toBe(6);

  resetKeptTailsForTests();
  const tab = page(pages, fork, FORK, true);
  await tab.daemon.asked;
  await flush();
  expect(tab.last()!.sessionId).toBe(FORK);
  expect(text(tab.last())).toContain("Tests added.");
  expect(tab.last()!.drewKeptTail).toBe(true);
  tab.daemon.release();
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown.split("Retry added.").length - 1).toBe(1);
  expect(shown.split("Tests added.").length - 1).toBe(1);
});

test("a fork that copied the history is not handed over from the chat it forked", async () => {
  const host = new Host();
  host.install();
  const pages = new Map<string, Page>([
    [PARENT, { events: PARENT_HISTORY }],
    [FORK, { events: PARENT_HISTORY.slice(0, 3) }],
  ]);
  // A copy renumbers from 1, so its log ends at or below the seq it branched at.
  const fork = { sessionId: FORK, createdAt: FORK_CREATED, lastSeq: 3, forkSeq: 4, parentId: PARENT };
  expect(await forkParent(pages, fork)).toBe(FORK);
  expect(host.tails.has(FORK)).toBe(false);
});

test("rows handed over as a fork's go when acpmux's page of the fork holds other records", async () => {
  const host = new Host();
  host.install();
  const pages = new Map<string, Page>([
    [PARENT, { events: PARENT_HISTORY }],
    // A fork whose log is not the chat's at the same seqs (a copy that ran past where it
    // branched): other records, at other times.
    [
      FORK,
      {
        at: START + 30_000,
        events: [
          prompt("Copied prompt"),
          reply(FORK, "Copied answer."),
          prompt("Copied again"),
          reply(FORK, "Copied end."),
          ["mux", "forked", {}],
        ],
      },
    ],
  ]);
  const fork = { sessionId: FORK, createdAt: FORK_CREATED, lastSeq: 5, forkSeq: 4, parentId: PARENT };
  expect(await forkParent(pages, fork)).toBe(FORK);
  expect(host.tails.has(FORK)).toBe(true);

  resetKeptTailsForTests();
  const tab = page(pages, fork, FORK, true);
  await tab.daemon.asked;
  await flush();
  expect(text(tab.last())).toContain("Tests added.");
  tab.daemon.release();
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("Copied end.");
  expect(shown).not.toContain("Tests added.");
  expect(shown).not.toContain("Retry added.");
});
