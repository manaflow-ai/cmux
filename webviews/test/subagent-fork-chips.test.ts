// l10n-allow-file: test fixture chat and subagent names, not shipped UI.
//
// A subagent's composer shows the model and mode it really runs on, read-only, and forks it on
// another one (subagents/SubagentForkChips.tsx; Leo 2026-11-22: "so for subagents, actually, are
// their permissions/model locked right then and there? does it make sense to be able to reveal the
// fork or whatever switching model behaviour for it?"). These hold:
//   - the chips' facts: a Claude subagent's mode follows its chat, a Codex one's was set at its
//     start; its own model when its spawn named one, else the chat's; no fork rows without the
//     daemon's `acp.session.fork.subagent.v1`;
//   - the client: the capability turns `canForkSubagent` on, `forkSubagent` sends
//     `acp.session.fork {sessionId, subagentId, live, model|mode}` and never touches the chat's own
//     model or mode, and without the capability it refuses before asking acpmux;
//   - the fork's transcript line names the subagent and its chat ("Forked from <subagent> of <chat>").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient, forkedSubagentName } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { subagentChipFacts } from "../src/agent-session/acpmux/subagents/subagentForkChipsModel";
import { experimentArm } from "../src/experiments/experiment";
import { subagentForkChipsLook } from "../src/agent-session/acpmux/subagents/subagentForkChips.experiment";
import { settleReact } from "./support/domTeardown";

const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) => translate(key, values);

const CLAUDE_MODES = [
  { id: "auto", name: "Auto" },
  { id: "default", name: "Manual" },
  { id: "acceptEdits", name: "Accept edits" },
  { id: "plan", name: "Plan" },
  { id: "bypassPermissions", name: "Bypass permissions" },
];
const CLAUDE_MODELS = [
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5", name: "Sonnet 5" },
];

test("a Claude subagent's mode chip follows its chat, and its model is the chat's unless its spawn named one", () => {
  const inherited = subagentChipFacts(
    {
      family: "claude",
      harness: "claude",
      chat: "Fix the flaky test",
      chatModel: "claude-opus-5-5",
      modeId: "bypassPermissions",
      modes: CLAUDE_MODES,
      models: CLAUDE_MODELS,
      canFork: true,
    },
    t,
  );
  expect(inherited.model).toBe("Opus 5.5");
  expect(inherited.mode).toEqual({ id: "bypassPermissions", name: "Bypass permissions" });
  expect(inherited.follows).toBe(true);
  expect(inherited.modeTip).toContain("Follows Fix the flaky test");
  expect(inherited.modelTip).toContain("Fix the flaky test");
  // Plan is a toggle of the chat's, not a mode a fork starts in.
  expect(inherited.forkModes.map((mode) => mode.id)).toEqual(["auto", "default", "acceptEdits", "bypassPermissions"]);
  expect(inherited.forkModels.map((model) => model.id)).toEqual(["claude-opus-5-5", "claude-sonnet-5"]);

  const own = subagentChipFacts(
    {
      family: "claude",
      chat: "Fix the flaky test",
      chatModel: "claude-opus-5-5",
      modes: CLAUDE_MODES,
      models: CLAUDE_MODELS,
      subagentModel: "haiku",
      canFork: true,
    },
    t,
  );
  expect(own.model).toBe("Haiku");
  expect(own.modelTip).not.toContain("Fix the flaky test");
  expect(own.mode).toBeUndefined();
});

test("a Codex subagent's mode was set at its start, and no fork rows show without the capability", () => {
  const facts = subagentChipFacts(
    {
      family: "codex",
      harness: "codex",
      chat: "Port the parser",
      chatModel: "gpt-6.2",
      chatModelName: "GPT-6.2",
      modeId: "agent-full-access",
      modes: [
        { id: "agent", name: "agent" },
        { id: "agent-full-access", name: "agent-full-access" },
      ],
      models: [{ id: "gpt-6.2", name: "GPT-6.2" }],
      canFork: false,
    },
    t,
  );
  expect(facts.model).toBe("GPT-6.2");
  expect(facts.mode).toEqual({ id: "agent-full-access", name: "Full access" });
  expect(facts.follows).toBe(false);
  expect(facts.modeTip).toContain("Port the parser");
  expect(facts.forkModels).toEqual([]);
  expect(facts.forkModes).toEqual([]);
});

test("a fork's forked record names the subagent it was made of", () => {
  expect(forkedSubagentName({ subagentName: " Test coverage " })).toBe("Test coverage");
  expect(forkedSubagentName({ forkOf: { sessionId: "p", subagentId: "a1", name: "Retry policy" } })).toBe(
    "Retry policy",
  );
  // A plain chat fork's forkOf names no subagent: the chat line stays.
  expect(forkedSubagentName({ forkOf: { sessionId: "p", name: "Chat" } })).toBeUndefined();
  expect(forkedSubagentName({ parentId: "p" })).toBeUndefined();
});

// The client against a stand-in acpmux.
const START = Date.UTC(2026, 10, 22, 9, 0, 0);
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
const CHAT = "chat-parent";
const FORK = "subagent-fork";

class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  readonly asked: Message[] = [];
  constructor(
    readonly capabilities: string[],
    readonly forkEvents: Record<string, unknown>[] = [],
  ) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    this.asked.push(message);
    queueMicrotask(() => this.answer(message));
  }
  close(): void {
    this.readyState = 3;
  }
  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: sessionId === CHAT ? "Audit the fetch helper" : "Test coverage",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      createdAt: START,
      ...(sessionId === FORK ? { parentId: CHAT } : {}),
    };
  }
  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: {
          acpmux: {
            origin: "local",
            extensions: [],
            operations: ["acp.session.fork"],
            capabilities: this.capabilities,
          },
        },
      };
    else if (message.method === "_acpmux/watch") result = { sessions: [this.summary(CHAT), this.summary(FORK)] };
    else if (message.method === "acp.session.fork")
      result = { sessionId: FORK, modes: null, configOptions: [], _meta: { acpmux: this.summary(FORK) } };
    else if (message.method === "_acpmux/attach") {
      const records =
        sessionId === FORK
          ? this.forkEvents.map((msg, index) => ({
              sessionId,
              seq: index + 1,
              at: START + index * 1000,
              dir: "mux",
              kind: "forked",
              msg,
            }))
          : [];
      result = { session: this.summary(sessionId), lastSeq: records.length, events: records, hasMore: false };
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
});

async function connect(capabilities: string[], sessionId = CHAT, forkEvents: Record<string, unknown>[] = []) {
  const daemon = new Daemon(capabilities, forkEvents);
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://fork.invalid/", token: "t", sessionId },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  live.push(client);
  await flush();
  return { daemon, client, last: () => drawn.at(-1) };
}

test("with acp.session.fork.subagent.v1, a chip's pick forks the subagent and leaves the chat's model and mode", async () => {
  const { daemon, client, last } = await connect(["acp.session.fork.subagent.v1"]);
  expect(last()?.canForkSubagent).toBe(true);
  const forked = await client.forkSubagent({ subagentId: "a39e817af38ddf5e7", model: "claude-sonnet-5" });
  expect(forked).toBe(FORK);
  const fork = daemon.asked.filter((message) => message.method === "acp.session.fork");
  expect(fork.map((message) => message.params)).toEqual([
    { sessionId: CHAT, subagentId: "a39e817af38ddf5e7", live: true, model: "claude-sonnet-5" },
  ]);
  await client.forkSubagent({ subagentId: "a39e817af38ddf5e7", mode: "default" });
  expect(daemon.asked.filter((message) => message.method === "acp.session.fork").at(-1)?.params).toEqual({
    sessionId: CHAT,
    subagentId: "a39e817af38ddf5e7",
    live: true,
    mode: "default",
  });
  // Never a switch of the chat's own model or mode.
  expect(daemon.asked.some((message) => /set_model|set_mode|set_config/.test(message.method))).toBe(false);
  // The chat stays the selected one: the fork opens in a tab of its own.
  expect(client.selectedSession).toBe(CHAT);
});

test("without the capability the chips offer no fork and the client asks acpmux nothing", async () => {
  const { daemon, client, last } = await connect([]);
  expect(last()?.canForkSubagent).toBeUndefined();
  await expect(client.forkSubagent({ subagentId: "a1", model: "claude-sonnet-5" })).rejects.toThrow();
  expect(daemon.asked.some((message) => message.method === "acp.session.fork")).toBe(false);
});

test("a fork of a subagent says which subagent and chat it was forked from", async () => {
  const { last } = await connect(["acp.session.fork.subagent.v1"], FORK, [
    { parentId: CHAT, subagentId: "a39e817af38ddf5e7", subagentName: "Test coverage" },
  ]);
  const lines = (last()?.rows ?? []).filter((row) => row.kind === "notice").map((row) => row.text);
  // The chat's name when the list has it by the fork record; an attach that answers before the list
  // (attachedBeforeList) has only the subagent's, as a plain fork's line has no chat then either.
  expect(
    lines.some((line) =>
      /^Forked from Test coverage( of Audit the fetch helper)?\. Everything above is from that subagent\.$/.test(
        line ?? "",
      ),
    ),
  ).toBe(true);
});

test("chat-sim: a chat forked from a subagent draws its Forked from line once, between its history and its turn", async () => {
  const { runSimulation } = await import("../src/agent-session/acpmux/sim/run");
  const { SCENARIOS } = await import("../src/agent-session/acpmux/sim/scenarios");
  const result = runSimulation(SCENARIOS["subagent-fork"]!());
  expect(result.violations).toEqual([]);
  const last = result.traces.at(-1)!;
  const forked = (last.rows ?? []).filter((row) => row.id.startsWith("forked-from-"));
  expect(forked.length).toBe(1);
});

test("the default arm is off, which is the pane as it was: no chips on a subagent's composer", () => {
  expect(subagentForkChipsLook.defaultArm).toBe("off");
  expect(experimentArm(subagentForkChipsLook)).toBe("off");
  expect(Object.keys(subagentForkChipsLook.arms)).toEqual(["off", "chips", "takeover", "hover"]);
});
