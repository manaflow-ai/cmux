// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A background subagent whose Agent call is on a page not loaded is named, never "Subagent" or a
// bare id (Leo, 2026-11-03: "why is the spacing like this it's weird"; his capture read "Subagent
// finished: Subagent" and "Sent to a6ab68f9"). acpmux repeats the subagent's name and task on its
// progress and end, and its progress says its agentId (cmux-tui/crates/acpmux): its end line reads its Agent
// call's description, and a SendMessage to its agentId reads "Sent to <that description>". The mock
// chat `mock-subagent-names` (mockFixture.ts) draws the same scene.
import { afterEach, expect, test } from "bun:test";
import { createElement, act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import {
  mockSessions,
  sessionHistory,
  SUBAGENT_NAMES_AGENT_ID,
  SUBAGENT_NAMES_SESSION,
  SUBAGENT_NAMES_TASK,
} from "../src/agent-session/acpmux/mockFixture";
import { agentMessage } from "../src/agent-session/acpmux/conversation/agentMessages";
import { AgentNamesContext, agentNames } from "../src/agent-session/acpmux/conversation/agentNames";
import { MessageCard } from "../src/agent-session/acpmux/conversation/MessageCard";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";

const CHAT = "0190a000-0000-7000-8000-0000000000f8";
const START = Date.UTC(2026, 10, 3, 4, 0, 0);

/// The mock chat's own history, as acpmux records it.
function history() {
  const scene = mockSessions.find((session) => session.sessionId === SUBAGENT_NAMES_SESSION)!;
  return sessionHistory(scene).map((step, index) => {
    const seq = index + 1;
    const base = { sessionId: CHAT, seq, at: START + seq * 1000 };
    if ("update" in step) {
      const params = { sessionId: "agent-1", update: step.update, ...(step.meta && { _meta: step.meta }) };
      return { ...base, dir: "in", kind: String(step.update.sessionUpdate), msg: { method: "session/update", params } };
    }
    return { ...base, dir: "mux", kind: step.mux, msg: step.msg ?? {} };
  });
}

function fakeDaemon(events: ReturnType<typeof history>) {
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness: "claude", status: "idle" };
  const lastSeq = events.at(-1)!.seq;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq };
      default:
        return null;
    }
  };
  return () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

/// The chat's snapshot once its subagent's end line is drawn.
async function snapshotOf(): Promise<any> {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
    },
    undefined,
    fakeDaemon(history()),
  );
  try {
    const deadline = performance.now() + 2_000;
    while (!snapshot?.rows?.some((row: any) => row.subagents?.[0]?.state === "completed")) {
      if (performance.now() > deadline) throw new Error("timed out waiting for the end line");
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    return snapshot;
  } finally {
    client.close();
  }
}

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function render(node: ReactNode): Promise<HTMLElement> {
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
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
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

test("a finished background subagent whose Agent call is not loaded reads its description", async () => {
  const snapshot = await snapshotOf();
  const row = snapshot.rows.find((row: any) => row.subagents?.[0]?.state === "completed");
  const container = await render(createElement(SubagentDoneLine, { row }));
  const sentence = container.querySelector(".cv-tool__text")!.textContent;
  expect(sentence).toBe(`Subagent finished: ${SUBAGENT_NAMES_TASK}`);
});

test("a SendMessage to a subagent's agentId reads Sent to <its description>", async () => {
  const snapshot = await snapshotOf();
  const agents = snapshot.rows.flatMap((row: any) => row.subagents ?? []);
  const items = snapshot.rows.flatMap((row: any) => row.items ?? []);
  const send = items.find((item: any) => item.tool?.title === "SendMessage");
  expect(send).toBeDefined();
  expect(JSON.parse(send.tool.inputSummary).to).toBe(SUBAGENT_NAMES_AGENT_ID);
  const container = await render(
    createElement(
      AgentNamesContext.Provider,
      { value: agentNames(agents) },
      createElement(MessageCard, { item: send, message: agentMessage(send.tool)! }),
    ),
  );
  expect(container.querySelector(".cv-agentmsg__words")!.textContent).toBe("Sent to");
  expect(container.querySelector(".cv-recipient")!.textContent).toBe(SUBAGENT_NAMES_TASK);
});
