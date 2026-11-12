// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// Leo, 2026-11-11: "why are only some chats forkable". His Claude Code chat runs a profile under its
// own family name (`claude-sr2`), and the pane read "forks every turn" from the family alone
// (`claude` or `codex`), so after a restart, reloading the chat from its history, only the latest
// message offered Fork and none offered Edit. acpmux forks such a chat through any completed turn
// (its harness is Claude Code: `config::turn_cut`, by kind). It now says so on the chat's row
// (`forksAnyTurn`), and the pane reads that. These load a chat from its history on a fresh page (a
// restart) and check every answered message's Fork and Edit; and, for an agent that forks only
// from its end, that the earlier messages keep a Fork control that says why instead of vanishing.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { forksAnyTurn, latestForkSeq, messageMenuTarget } from "../src/agent-session/acpmux/conversation/messageMenu";
import { promptTurns, trackEditableTurns } from "../src/agent-session/acpmux/conversation/editPrompt";
import { TurnActionsContext, type TurnActions } from "../src/agent-session/acpmux/conversation/turnActions";
import { UserBubble } from "../src/agent-session/acpmux/conversation/UserBubble";

const START = Date.UTC(2026, 10, 11, 9, 0, 0);
const CHAT = "sr2-chat";
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;
let live: AcpmuxDirectClient[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  for (const client of live) client.close();
  live = [];
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const prompt = (text: string): Step => ["mux", "user_message", { text }];
const reply = (text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId: CHAT, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];
const ended: Step = ["mux", "turn_result", { status: "completed" }];
const HISTORY: Step[] = [
  prompt("Look at the retry path"),
  reply("Retry added."),
  ended,
  prompt("And tests"),
  reply("Tests added."),
  ended,
  prompt("Now the docs"),
  reply("Docs updated."),
  ended,
];

/// acpmux holding one finished chat: its row (`summary`) as `_acpmux/watch` and attach list it.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  constructor(readonly summary: Record<string, unknown>) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string };
    if (message.id !== undefined) queueMicrotask(() => this.answer(message as { id: number; method: string }));
  }
  close(): void {
    this.readyState = 3;
  }
  private answer(message: { id: number; method: string }): void {
    let result: unknown = {};
    const records = HISTORY.map(([dir, kind, msg], index) => ({
      sessionId: CHAT,
      seq: index + 1,
      at: START + (index + 1) * 1000,
      dir,
      kind,
      msg,
    }));
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: ["acp.session.fork"] } },
      };
    else if (message.method === "_acpmux/watch") result = { sessions: [this.summary] };
    else if (message.method === "_acpmux/attach")
      result = { session: this.summary, lastSeq: records.length, events: records, hasMore: false };
    else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

/// A fresh page (the app restarted) loading the chat from acpmux's history.
async function reload(summary: Record<string, unknown>): Promise<AcpmuxSnapshot> {
  const daemon = new Daemon({
    sessionId: CHAT,
    cwd: "/home/dev/project",
    title: "Retry path",
    status: "idle",
    turnCount: 3,
    updatedAt: START,
    createdAt: START,
    ...summary,
  });
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://restart.invalid/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  live.push(client);
  await flush();
  const last = drawn.at(-1)!;
  expect(last.rows.filter((row) => row.kind === "user")).toHaveLength(3);
  return last;
}

/// Each prompt's bubble, as the transcript draws it with the App's per-message actions.
async function bubbles(snapshot: AcpmuxSnapshot) {
  const container = installDom();
  const forkAny = forksAnyTurn(snapshot);
  const actions: TurnActions = {
    fork: () => {},
    forkSeq: latestForkSeq(snapshot.rows),
    forkAny,
    promptTurns: promptTurns(snapshot.rows),
  };
  const prompts = snapshot.rows.filter((row) => row.kind === "user");
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={actions}>
        {prompts.map((row) => (
          <div key={row.id} data-prompt={row.id}>
            <UserBubble row={row} text={row.text ?? ""} />
          </div>
        ))}
      </TurnActionsContext.Provider>,
    );
  });
  return prompts.map((row) => {
    const fork = container.querySelector(`[data-prompt="${row.id}"] .cv-fork-button`);
    return { id: row.id, state: fork?.getAttribute("data-fork-state"), title: fork?.getAttribute("title") };
  });
}

test("after a restart, every answered message of a Claude Code chat under its own family forks and edits", async () => {
  const snapshot = await reload({ harness: "claude-sr2", family: "claude-sr2", forksAnyTurn: true });
  expect(forksAnyTurn(snapshot)).toBe(true);
  const prompts = snapshot.rows.filter((row) => row.kind === "user");
  // Right-click Fork, on every prompt.
  for (const row of prompts) expect(messageMenuTarget(snapshot, row.id)?.forkSeq).toBeNumber();
  // The Fork under each bubble, every one live.
  expect((await bubbles(snapshot)).map((bubble) => bubble.state)).toEqual(["idle", "idle", "idle"]);
  // Edit: every prompt after the first (the first has no turn before it to fork through).
  const edits = trackEditableTurns(snapshot.rows, forksAnyTurn(snapshot)).seqs;
  expect([...edits.keys()]).toEqual(prompts.slice(1).map((row) => row.id));
});

test("an agent that forks only from its end keeps Fork on earlier messages, saying why", async () => {
  const snapshot = await reload({ harness: "opencode", family: "opencode", forksAnyTurn: false });
  expect(forksAnyTurn(snapshot)).toBe(false);
  const drawn = await bubbles(snapshot);
  expect(drawn.map((bubble) => bubble.state)).toEqual(["unavailable", "unavailable", "idle"]);
  expect(drawn[0]!.title).toBe(translate("turn.forkLatestOnly"));
  expect(trackEditableTurns(snapshot.rows, forksAnyTurn(snapshot)).seqs.size).toBe(0);
});

test("an older acpmux that does not say is read by the chat's family", async () => {
  expect(forksAnyTurn(await reload({ harness: "claude", family: "claude" }))).toBe(true);
  expect(forksAnyTurn(await reload({ harness: "claude-sr2", family: "claude-sr2" }))).toBe(false);
});
