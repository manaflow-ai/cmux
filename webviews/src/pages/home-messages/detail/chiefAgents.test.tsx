// A Chief chat's agents on the Messages page: the host's stream parses into the transcript's agents
// rows and the agents' chats, the rows go after the message they follow, and a pill's click opens
// the agent's session through the host, or its chat in the pane when it has no link.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { HomeConversation, HomeMessage } from "../../home-channels/types";
import type { PageClient } from "../../shared/pageClient";
import { AgentPills } from "../cards/pills/AgentPills";
import { AgentSidePane } from "../cards/pills/AgentSidePane";
import { cardStrings } from "../cards/strings";
import { estimateRow, RowCache, transcriptRows } from "../transcript/rows";
import { AgentOps, parseChiefAgents, useAgentPane, type ChiefAgents } from "./chiefAgents";

const EVENT = {
  conversation: "c1",
  rows: [
    { after: null, group: "g0", peers: ["a0"], titles: ["Warm up"], states: ["queued"], unread: [false] },
    {
      after: "m1",
      group: "g1",
      peers: ["a1", "a2"],
      titles: ["Fix it", "Test it"],
      states: ["told", "reported"],
      unread: [false, true],
    },
    { group: "", peers: ["x"] },
    { group: "g9", peers: [] },
  ],
  threads: [
    {
      peer: "a1",
      title: "Fix it",
      state: "told",
      task: "Fix the bug",
      entries: [{ id: "e1", sender: "chief", text: "go" }, { id: "e2", sender: "nobody", text: "ok" }, { id: 3 }],
      startedAt: 1_000,
      workspaceLink: "cmux://chief/h/session/s1",
    },
    { peer: "a2", title: "Test it", state: "reported", entries: [], startedAt: 2_000, endedAt: 9_000 },
    { peer: "bad" },
  ],
};

test("the stream's event parses, and what is not one is dropped", () => {
  const agents = parseChiefAgents(EVENT)!;
  expect(agents.conversation).toBe("c1");
  expect(agents.rows.map((row) => [row.group, row.after])).toEqual([
    ["g0", undefined],
    ["g1", "m1"],
  ]);
  expect(agents.rows[1]!.row).toEqual({
    peers: ["a1", "a2"],
    titles: ["Fix it", "Test it"],
    states: ["told", "reported"],
    unread: [false, true],
  });
  expect([...agents.threads.keys()]).toEqual(["a1", "a2"]);
  expect(agents.threads.get("a1")!.entries).toEqual([
    { id: "e1", sender: "chief", text: "go" },
    { id: "e2", sender: "agent", text: "ok" },
  ]);
  expect(agents.threads.get("a2")!.endedAt).toBe(9_000);
  expect(parseChiefAgents(null)).toBeUndefined();
  expect(parseChiefAgents({ rows: [] })).toBeUndefined();
});

const chat: HomeConversation = {
  id: "c1",
  owner: "local",
  title: "",
  kind: "chief",
  participants: [
    { id: "me", kind: "human", name: "Me", chief: false },
    { id: "chief", kind: "agent", name: "Chief", chief: true },
  ],
  lastSeq: 2,
  rev: 1,
  updatedAt: 0,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
};
const message = (id: string, seq: number, author: string): HomeMessage => ({
  id,
  conversation: "c1",
  seq,
  author,
  createdAt: 60_000 * seq,
  retracted: false,
  parts: [{ type: "text", text: id, mentions: [] }],
  reactions: [],
});

test("each agents row goes after its message, also when the message's rows are kept", () => {
  const agents = parseChiefAgents(EVENT)!;
  const messages = [message("m1", 1, "me"), message("m2", 2, "chief")];
  const cache = new RowCache();
  const first = transcriptRows({ me: "me", conversation: chat, messages, agents: agents.rows }, 0, cache);
  const order = (rows: typeof first) =>
    rows.map((row) => (row.kind === "bubble" ? row.message.id : row.kind === "agents" ? row.key : row.kind));
  expect(order(first)).toEqual(["agents:g0", "separator", "m1", "receipt", "agents:g1", "m2"]);
  // A new report changes only the agents: the messages keep their rows, and the pills still show.
  const later = parseChiefAgents({ ...EVENT, rows: [EVENT.rows[1]] })!;
  const second = transcriptRows({ me: "me", conversation: chat, messages, agents: later.rows }, 0, cache);
  expect(order(second)).toEqual(["separator", "m1", "receipt", "agents:g1", "m2"]);
  const pills = second.find((row) => row.kind === "agents")!;
  expect(estimateRow(pills)).toBe(pills.gap + 8 + 32 * 2);
  // With older messages not loaded, a row before the first loaded one waits for them.
  const older = transcriptRows({ me: "me", conversation: chat, messages, agents: agents.rows, hasOlder: true }, 0);
  expect(order(older)).toEqual(["older", "separator", "m1", "receipt", "agents:g1", "m2"]);
});

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

function Harness({ host, agents }: { host: PageClient | null; agents: ChiefAgents }) {
  const strings = cardStrings(["en"]);
  const model = useAgentPane(host, "c1", agents, strings, (url) => void host?.call(AgentOps.stream + ".link", { url }));
  return (
    <>
      <AgentPills row={model.rows![1]!.row} strings={model.pills.strings} onOpen={model.pills.open} />
      <AgentSidePane
        pane={model.pane}
        content={model.content}
        strings={strings}
        onSelect={model.select}
        onClose={model.close}
        onGoToWorkspace={model.goToWorkspace}
        onSend={model.send}
      />
    </>
  );
}

function mount(host: PageClient | null) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Harness host={host} agents={parseChiefAgents(EVENT)!} />));
  return dom.window.document;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function fakeHost() {
  const calls: [string, unknown][] = [];
  const host = {
    call: async (op: string, params: unknown) => {
      calls.push([op, params]);
      return null;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  } as unknown as PageClient;
  return { host, calls };
}

const click = (element: Element) =>
  act(() => void element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));

test("a pill with a link opens the agent's session through the host; one without opens its chat in the pane", () => {
  const { host, calls } = fakeHost();
  const doc = mount(host);
  const [linked, unlinked] = [...doc.querySelectorAll(".hm-pill")];
  click(linked!);
  expect(calls).toEqual([
    [AgentOps.stream + ".link", { url: "cmux://chief/h/session/s1" }],
    [AgentOps.seen, { conversation: "c1", peer: "a1" }],
  ]);
  expect(doc.querySelector(".hm-agent-pane")).toBeNull();
  calls.length = 0;
  click(unlinked!);
  expect(doc.querySelector(".hm-agent-pane")).not.toBeNull();
  expect(doc.querySelector(".hm-agent-pane__tab-name")!.textContent).toBe("Test it");
  expect(calls).toEqual([[AgentOps.seen, { conversation: "c1", peer: "a2" }]]);
  click(doc.querySelector(".hm-agent-pane__tab-close")!);
  expect(doc.querySelector(".hm-agent-pane")).toBeNull();
});

test("without a host a pill opens its chat in the pane", () => {
  const doc = mount(null);
  click(doc.querySelector(".hm-pill")!);
  expect(doc.querySelector(".hm-agent-pane__tab-name")!.textContent).toBe("Fix it");
});
