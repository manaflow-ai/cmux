// l10n-allow-file: test fixture prompts and chat names, not shipped UI.
// acpmux's agent pair guard (#21975) pauses two agent chats that keep messaging each other without
// progress and records `agent_pair_paused`, `agent_pair_held` and `agent_pair_resumed` in both
// transcripts. Without a row for them the person saw nothing: the other agent's messages stopped
// arriving with no say why and no way to let them through. The pause is now one quiet row that
// names the peer, counts the held messages and offers Resume (`_acpmux/agent_pair_resume`); once
// the pair resumes it collapses to "Resumed messages with <peer>". A held message never draws as
// a prompt.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { AgentPairNote } from "../src/agent-session/acpmux/conversation/AgentPairNote";
import { reduceAgentPair } from "../src/agent-session/acpmux/conversation/agentPairs";
import { translate } from "../src/agent-session/acpmux/i18n";

const CHAT = "0190a000-0000-7000-8000-0000000000a1";
const PEER = "0190a000-0000-7000-8000-0000000000b2";
const START = Date.UTC(2026, 9, 19, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

const paused = (fields: Record<string, unknown> = {}): Step => [
  "mux",
  "agent_pair_paused",
  {
    peer: PEER,
    peerName: "Reviewer",
    reason: "alternating",
    count: 10,
    promptId: "p-9",
    resume: "_acpmux/agent_pair_resume",
    ...fields,
  },
];
const held = (promptId: string, text: string): Step => [
  "mux",
  "agent_pair_held",
  {
    from: PEER,
    fromName: "Reviewer",
    to: CHAT,
    promptId,
    text,
    provenance: { kind: "agent_message", from: PEER },
    prompt: [{ type: "text", text }],
    client: "acpmux",
  },
];

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events;
/// `requests` lists every request the page sent.
function fakeDaemon(history: ReturnType<typeof record>) {
  let socket: any;
  const requests: { method: string; params: any }[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      case "_acpmux/agent_pair_resume":
        return { sessionId: params.sessionId, resumed: 1, delivered: 2 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        requests.push({ method: message.method, params: message.params });
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push, requests };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}

const pairs = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "agentPair").map((row) => row.agentPair);

test("a pause is one row that counts the held messages and collapses when the pair resumes", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Ask the reviewer to sign off" }],
      ["mux", "turn_result", { status: "completed" }],
      paused(),
      held("p-9", "LGTM? Please confirm again."),
    ]),
  );
  const { rows } = await connect(daemon);
  expect(pairs(rows())).toEqual([{ peer: PEER, peerName: "Reviewer", reason: "alternating", count: 10, held: 1 }]);
  daemon.push(record([held("p-10", "Still waiting on your sign-off.")], 5));
  expect(pairs(rows())[0]?.held).toBe(2);
  // A held message is not a prompt: the only user row is the person's own.
  expect(
    rows()
      .filter((row) => row.kind === "user")
      .map((row) => row.text),
  ).toEqual(["Ask the reviewer to sign off"]);

  daemon.push(record([["mux", "agent_pair_resumed", { peer: PEER, by: "request", delivered: 2 }]], 6));
  expect(pairs(rows())).toEqual([
    { peer: PEER, peerName: "Reviewer", reason: "alternating", count: 10, held: 2, resumed: true },
  ]);

  // A later pause with the same peer is a row of its own; the resumed one stays resumed.
  daemon.push(record([paused({ reason: "repeating", count: 4 })], 7));
  expect(pairs(rows()).map((pair) => [pair?.reason, pair?.resumed ?? false])).toEqual([
    ["alternating", true],
    ["repeating", false],
  ]);
});

test("a reload draws the same rows from history", async () => {
  const steps: Step[] = [
    paused(),
    held("p-9", "again"),
    held("p-10", "and again"),
    ["mux", "agent_pair_resumed", { peer: PEER, by: "person", delivered: 2 }],
  ];
  const { rows } = await connect(fakeDaemon(record(steps)));
  expect(pairs(rows())).toEqual([
    { peer: PEER, peerName: "Reviewer", reason: "alternating", count: 10, held: 2, resumed: true },
  ]);
});

test("records for another peer, or without a pause, change nothing", () => {
  const rows = new Map<string, AcpmuxRow>();
  const at = START;
  expect(reduceAgentPair(rows, { seq: 1, at, kind: "agent_pair_held", msg: { from: PEER } })).toBe(true);
  expect(reduceAgentPair(rows, { seq: 2, at, kind: "agent_pair_resumed", msg: { peer: PEER } })).toBe(true);
  expect(rows.size).toBe(0);
  reduceAgentPair(rows, { seq: 3, at, kind: "agent_pair_paused", msg: { peer: PEER, peerName: "R", count: 3 } });
  reduceAgentPair(rows, { seq: 4, at, kind: "agent_pair_held", msg: { from: "someone-else" } });
  reduceAgentPair(rows, { seq: 5, at, kind: "agent_pair_resumed", msg: { peer: "someone-else" } });
  expect([...rows.values()].map((row) => [row.version, row.agentPair])).toEqual([
    [1, { peer: PEER, peerName: "R", reason: "alternating", count: 3, held: 0 }],
  ]);
  expect(reduceAgentPair(rows, { seq: 6, at, kind: "turn_started", msg: {} })).toBe(false);
});

// ---------- The row itself ----------

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
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

test("the paused row names the peer, counts held messages, and Resume sends agent_pair_resume", async () => {
  const daemon = fakeDaemon(record([paused(), held("p-9", "again"), held("p-10", "and again")]));
  const { client, rows } = await connect(daemon);
  const pair = pairs(rows())[0]!;
  const host = installDom();
  root = createRoot(host);
  await act(async () => root!.render(<AgentPairNote pair={pair} onResume={(peer) => client.resumeAgentPair(peer)} />));

  expect(host.textContent).toContain(translate("agentPair.paused.alternating", { peer: "Reviewer", n: 10 }));
  expect(host.textContent).toContain("Paused messages with Reviewer: the two agents went back and forth 10 times");
  expect(host.textContent).toContain(translate("agentPair.held", { n: 2 }));
  const button = host.querySelector("button")!;
  expect(button.textContent).toBe(translate("agentPair.resume"));

  await act(async () => {
    button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(daemon.requests.filter((request) => request.method === "_acpmux/agent_pair_resume")).toEqual([
    { method: "_acpmux/agent_pair_resume", params: { sessionId: CHAT, peerSessionId: PEER } },
  ]);
});

test("a resumed pair is one line without Resume; an unnamed peer reads as another agent", async () => {
  const host = installDom();
  root = createRoot(host);
  const pair = { peer: PEER, peerName: "", reason: "repeating" as const, count: 4, held: 0 };
  await act(async () => root!.render(<AgentPairNote pair={pair} onResume={async () => undefined} />));
  expect(host.textContent).toContain("Paused messages with another agent: the same message was sent 4 times in a row");
  // Nothing held on this side: no count.
  expect(host.textContent).not.toContain(translate("agentPair.held", { n: 0 }));

  await act(async () => root!.render(<AgentPairNote pair={{ ...pair, peerName: "Deploy", resumed: true }} />));
  expect(host.textContent).toBe("Resumed messages with Deploy");
  expect(host.querySelector("button")).toBeNull();
});

test("a failed Resume says so and can be pressed again", async () => {
  const host = installDom();
  root = createRoot(host);
  let calls = 0;
  const pair = { peer: PEER, peerName: "Reviewer", reason: "alternating" as const, count: 10, held: 1 };
  await act(async () =>
    root!.render(
      <AgentPairNote
        pair={pair}
        onResume={() => {
          calls += 1;
          return Promise.reject(new Error("refused"));
        }}
      />,
    ),
  );
  const click = () =>
    act(async () => {
      host.querySelector("button")!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  await click();
  expect(host.textContent).toContain(translate("agentPair.resumeFailed"));
  expect(host.querySelector("button")!.disabled).toBe(false);
  await click();
  expect(calls).toBe(2);
});
