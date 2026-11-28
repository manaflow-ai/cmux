// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// The first switch to a chat this page never showed did all the work a switch back skips: its rows
// were folded into new objects and every turn was shaped again (settled-page bench, chat_switch).
// While the page is idle the client folds the likely next chat's kept tail ahead (direct.ts
// `warmRows`) and the pane shapes those rows into turns (pane/useTurnActions.ts `shapeAhead`).
// These hold that work to being reused, not redone:
//
//   - the first frame of a switch to a chat folded ahead draws the very row objects folded ahead;
//   - the turns shaped ahead are reused whole by that frame's shaping;
//   - a chat that ran on after it was folded ahead draws what it says now, not the rows folded ahead.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient, type WarmedChat } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { NO_MESSAGE_BREAKS, turnViewFrom, type TurnView } from "../src/agent-session/acpmux/conversation/turns";
import { shapeAhead } from "../src/agent-session/acpmux/pane/useTurnActions";
import type { SubagentRows } from "../src/agent-session/acpmux/subagents/subagentRows";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 28, 9, 0, 0);
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
const DONE: Step = ["mux", "turn_result", { status: "completed" }];

/** acpmux for two chats, each answering its attach with `pages[sessionId]`; `hold` keeps one attach unanswered. */
class Daemon {
  readonly sessionA: string;
  readonly sessionB: string;
  readonly pages = new Map<string, Step[]>();
  hold?: string;
  private held?: { socket: Socket; message: Message };
  private holding?: () => void;
  asked = new Promise<void>((resolve) => (this.holding = resolve));

  constructor(name: string) {
    this.sessionA = `${name}-a`;
    this.sessionB = `${name}-b`;
  }

  /** One connection: each client opens its own. */
  socket(): Socket {
    return new Socket(this);
  }

  heard(socket: Socket, message: Message): void {
    if (message.id === undefined) return;
    if (message.method === "_acpmux/attach" && message.params?.sessionId === this.hold) {
      this.held = { socket, message };
      this.hold = undefined;
      this.holding?.();
      return;
    }
    queueMicrotask(() => this.answer(socket, message));
  }

  release(): void {
    const held = this.held;
    this.held = undefined;
    if (held) this.answer(held.socket, held.message);
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: "idle",
      turnCount: 2,
      updatedAt: START,
    };
  }

  private answer(socket: Socket, message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch")
      result = { sessions: [this.summary(this.sessionA), this.summary(this.sessionB)] };
    else if (message.method === "_acpmux/attach") {
      const records = (this.pages.get(sessionId) ?? []).map(([dir, kind, msg], at) => ({
        sessionId,
        seq: at + 1,
        at: START + (at + 1) * 1000,
        dir,
        kind,
        msg,
      }));
      result = { session: this.summary(sessionId), lastSeq: records.at(-1)?.seq ?? 0, events: records, hasMore: false };
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    if (socket.readyState === 1)
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

class Socket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;

  constructor(private readonly daemon: Daemon) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    this.daemon.heard(this, JSON.parse(raw) as Message);
  }

  close(): void {
    this.readyState = 3;
  }
}

const connect = async (daemon: Daemon, sessionId: string) => {
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://warm.invalid/", token: "t", sessionId },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon.socket() as unknown as WebSocket,
  );
  return { client, last: () => drawn.at(-1)! };
};

/** Two chats of a few turns each; chat B gets a kept tail from a page that showed it, then closed. */
const twoChats = async (name: string) => {
  const daemon = new Daemon(name);
  const [A, B] = [daemon.sessionA, daemon.sessionB];
  daemon.pages.set(A, [prompt("Look at the retry path"), reply(A, "Retry added."), DONE]);
  daemon.pages.set(B, [
    prompt("Docs"),
    reply(B, "Docs updated."),
    DONE,
    prompt("And the changelog"),
    reply(B, "Changelog entry added."),
    DONE,
  ]);
  const earlier = await connect(daemon, B);
  await earlier.client.select(A);
  earlier.client.close();
  return { daemon, A, B };
};

const warmedOn = (client: AcpmuxDirectClient, sessionId: string) =>
  new Promise<WarmedChat>((resolve) => {
    const stop = client.onWarmed((warmed) => {
      if (warmed.sessionId !== sessionId) return;
      stop();
      resolve(warmed);
    });
  });

test("the first switch to a chat folded ahead draws the rows and turns made ahead", async () => {
  const { daemon, A, B } = await twoChats("warm-first");
  const { client, last } = await connect(daemon, A);
  try {
    const warmed = await warmedOn(client, B);
    expect(warmed.rows.length).toBeGreaterThan(0);
    const pastTurns = new Map<string, { sessionId: string | undefined; turns: TurnView; subagents: SubagentRows }>();
    const expanded = new Set<string>();
    shapeAhead(warmed, {
      expanded,
      doneLines: new Map(),
      workflowLabsEnabled: false,
      splitSilent: false,
      clockOffset: undefined,
      pastTurns,
    });
    const ahead = pastTurns.get(B)!.turns;
    // B's attach held: the frame the switch lands on is drawn from its kept tail.
    daemon.hold = B;
    const opening = client.select(B);
    await daemon.asked;
    const shown = last();
    expect(shown.sessionId).toBe(B);
    // Every row the switch drew is the object folded ahead (OrderedRows.keepSame), not a new copy.
    expect(shown.rows.length).toBe(warmed.rows.length);
    shown.rows.forEach((row, at) => expect(row).toBe(warmed.rows[at]!));
    // The switch's shaping reuses the turns shaped ahead: it shaped none again.
    const turns = turnViewFrom(
      shown.rows,
      expanded,
      { clockOffset: undefined, agentFamily: warmed.family, messageBreaks: NO_MESSAGE_BREAKS },
      ahead,
    );
    expect(turns.reusedRows).toBeGreaterThan(0);
    expect(turns.rows.slice(0, turns.reusedRows)).toEqual(ahead.rows.slice(0, turns.reusedRows));
    turns.rows.slice(0, turns.reusedRows).forEach((row, at) => expect(row).toBe(ahead.rows[at]!));
    daemon.release();
    await opening;
  } finally {
    client.close();
  }
});

test("a chat that ran on after it was folded ahead draws what it says now", async () => {
  const { daemon, A, B } = await twoChats("warm-ran-on");
  const { client, last } = await connect(daemon, A);
  try {
    await warmedOn(client, B);
    // B ran on: its attach answers a reply the rows folded ahead do not hold.
    daemon.pages.get(B)!.push(prompt("Tag it"), reply(B, "Tagged v1.2."), DONE);
    await client.select(B);
    const words = last()
      .rows.map((row) => JSON.stringify(row))
      .join(" ");
    expect(words).toContain("Changelog entry added.");
    expect(words).toContain("Tagged v1.2.");
  } finally {
    client.close();
  }
});
