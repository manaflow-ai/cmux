// Review round 6 of cmux#37736 (package "agent"): the native transcript's Chief surfaces on the
// React Messages page. Stop, Escape, Cmd-., Option-click Stop all agents with its toast and Restart,
// and Continue after a stop (ChatController+Stop.swift, HomeChiefTurnActions, HomeHostView+StopAll);
// the toast's room under the newest message (+ToastRoom.swift); rows added beside the messages.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
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

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { ChiefTurn, CHIEF_TURN_OPS, stopAllMessage } = await import("../src/pages/home-messages/transcript/chiefTurn");
const { withExtras } = await import("../src/pages/home-messages/transcript/extras");
type PageClient = import("../src/pages/shared/pageClient").PageClient;
type TranscriptRow = import("../src/pages/home-messages/transcript/rows").TranscriptRow;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/** A host that answers each op from `answers` and records the calls. */
function fakeHost(answers: Record<string, unknown | Error>) {
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const host: PageClient = {
    call: async <T,>(op: string, params: Record<string, unknown> = {}) => {
      calls.push({ op, params });
      const answer = answers[op];
      if (answer instanceof Error) throw answer;
      return answer as T;
    },
    subscribe: () => Promise.reject(new Error("none")),
    handle: () => () => {},
  } as unknown as PageClient;
  return { host, calls };
}

test("Stop goes to the conversation's Chief, and Continue follows a stop the brain accepted", async () => {
  const { host, calls } = fakeHost({
    [CHIEF_TURN_OPS.stop]: { stopped: true },
    [CHIEF_TURN_OPS.continue]: { continued: true },
  });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 4);
  expect(turn.getSnapshot()).toEqual({ working: true, continueAvailable: false });
  turn.stop();
  await settle();
  expect(calls).toEqual([{ op: CHIEF_TURN_OPS.stop, params: { conversation: "c1" } }]);
  // Still working until the next idle snapshot: no Continue yet.
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.update(false, 4);
  expect(turn.getSnapshot().continueAvailable).toBe(true);
  turn.continueTurn();
  await settle();
  expect(calls.at(-1)?.op).toBe(CHIEF_TURN_OPS.continue);
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.dispose();
});

test("a new message or a new turn ends a stop's Continue", async () => {
  const { host } = fakeHost({ [CHIEF_TURN_OPS.stop]: { stopped: true } });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 4);
  turn.stop();
  await settle();
  turn.update(false, 4);
  expect(turn.getSnapshot().continueAvailable).toBe(true);
  turn.update(false, 5);
  expect(turn.getSnapshot().continueAvailable).toBe(false);
  turn.dispose();
});

test("Stop all agents shows what stopped, and Restart starts those subagents again", async () => {
  const { host, calls } = fakeHost({
    [CHIEF_TURN_OPS.stopAll]: {
      stopped: true,
      subagents: ["a1", "a2"],
      errors: ["a3: busy"],
      note: "a4 is still starting",
    },
    [CHIEF_TURN_OPS.restart]: { restarted: true },
  });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 1);
  turn.stop(true);
  await settle();
  const toast = turn.getSnapshot().toast!;
  // One row (#38690): not "all" while one refused, and the still-starting note only in the tooltip.
  expect(toast.message).toBe("Stopped a1 and a2 · 1 could not be stopped");
  expect(toast.detail).toBe("a3: busy\na4 is still starting");
  expect(toast.restart).toEqual(["a1", "a2"]);
  turn.restart(toast.restart!);
  await settle();
  expect(calls.at(-1)).toEqual({ op: CHIEF_TURN_OPS.restart, params: { conversation: "c1", names: ["a1", "a2"] } });
  expect(turn.getSnapshot().toast).toBeUndefined();
  turn.dispose();
});

test("the stop-all lines when no subagent ran", () => {
  expect(stopAllMessage({ stopped: true, subagents: [], errors: [] }, strings)).toBe(
    "Stopped the Chief; no subagents were running",
  );
  expect(stopAllMessage({ stopped: false, subagents: [], errors: [] }, strings)).toBe("No agents were running");
});

test("the stop-all row says all only when none refused, and keeps the note off the row (#38690)", () => {
  expect(stopAllMessage({ stopped: false, subagents: ["a1"], errors: [], note: "a2 is still starting" }, strings)).toBe(
    "Stopped all agents: a1",
  );
  expect(stopAllMessage({ stopped: false, subagents: ["a1"], errors: ["a2: busy"] }, strings)).toBe(
    "Stopped a1 · 1 could not be stopped",
  );
  expect(stopAllMessage({ stopped: true, subagents: [], errors: ["a2: busy"] }, strings)).toBe(
    "Stopped the Chief · 1 could not be stopped",
  );
});

test("a refused Start now shows the Chief's words in the toast; a start resolves true", async () => {
  const refusing = fakeHost({ [CHIEF_TURN_OPS.startAgent]: new Error("a2 is not queued any more") });
  const turn = new ChiefTurn(refusing.host, "c1", strings);
  expect(await turn.startAgent("a2")).toBe(false);
  expect(refusing.calls).toEqual([{ op: CHIEF_TURN_OPS.startAgent, params: { conversation: "c1", agent: "a2" } }]);
  expect(turn.getSnapshot().toast?.message).toBe("a2 is not queued any more");
  turn.dispose();
  const starting = fakeHost({ [CHIEF_TURN_OPS.startAgent]: { started: true } });
  const ok = new ChiefTurn(starting.host, "c1", strings);
  expect(await ok.startAgent("a2")).toBe(true);
  expect(ok.getSnapshot().toast).toBeUndefined();
  ok.dispose();
});

test("a refused stop says why in a toast", async () => {
  const { host } = fakeHost({ [CHIEF_TURN_OPS.stop]: Object.assign(new Error("The Chief could not be reached")) });
  const turn = new ChiefTurn(host, "c1", strings);
  turn.update(true, 1);
  turn.stop();
  await settle();
  expect(turn.getSnapshot().toast?.message).toBe("The Chief could not be reached");
  turn.dispose();
});

async function renderComposer(container: HTMLElement, props: Partial<Parameters<typeof MessageComposer>[0]>) {
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} {...props} />);
  });
  await settle();
}

test("while the Chief works the emoji button is Stop; Option-click stops all agents", async () => {
  const container = installDom();
  const stops: boolean[] = [];
  await renderComposer(container, {
    chief: { working: true, continueAvailable: false, onStop: (all) => stops.push(all), onContinue: () => {} },
  });
  const stop = container.querySelector<HTMLButtonElement>(`button[aria-label="${strings.t("compose.stop")}"]`)!;
  expect(stop).not.toBeNull();
  expect(container.querySelector(`button[aria-label="${strings.t("compose.emoji")}"]`)).toBeNull();
  expect(stop.title).toBe("Stop the Chief (Option-click: Stop All Agents)");
  await act(async () => stop.click());
  await act(async () => stop.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, altKey: true })));
  expect(stops).toEqual([false, true]);
});

test("Escape and Cmd-. in the message box stop a working Chief", async () => {
  const container = installDom();
  const stops: boolean[] = [];
  await renderComposer(container, {
    chief: { working: true, continueAvailable: false, onStop: (all) => stops.push(all), onContinue: () => {} },
  });
  const field = container.querySelector<HTMLElement>(".ProseMirror")!;
  expect(field).not.toBeNull();
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    field.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: ".", metaKey: true, bubbles: true, cancelable: true }),
    );
  });
  expect(stops).toEqual([false, false]);
});

test("after a stop the button is Continue; idle it is the emoji button again", async () => {
  const container = installDom();
  let continued = 0;
  await renderComposer(container, {
    chief: { working: false, continueAvailable: true, onStop: () => {}, onContinue: () => (continued += 1) },
  });
  const button = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${strings.t("home.compose.continue")}"]`,
  )!;
  expect(button).not.toBeNull();
  await act(async () => button.click());
  expect(continued).toBe(1);
  act(() =>
    root!.render(
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        chief={{ working: false, continueAvailable: false, onStop: () => {}, onContinue: () => {} }}
      />,
    ),
  );
  expect(container.querySelector(`button[aria-label="${strings.t("compose.emoji")}"]`)).not.toBeNull();
});

const bubble = (id: string): TranscriptRow =>
  ({ kind: "bubble", key: `part:${id}:0`, gap: 0, message: { id } }) as unknown as TranscriptRow;
const receipt = (id: string): TranscriptRow =>
  ({ kind: "receipt", key: `receipt:${id}`, gap: 0, receipt: "read" }) as unknown as TranscriptRow;

test("added rows go after their message's own rows and at the end", () => {
  const rows = [bubble("m1"), bubble("m1"), receipt("m1"), bubble("m2")];
  const shown = withExtras(rows, {
    after: new Map([["m1", [{ key: "agents:m1", estimate: 30, node: null }]]]),
    tail: [{ key: "status", estimate: 20, node: null }],
  });
  expect(shown.map((row) => row.key)).toEqual([
    "part:m1:0",
    "part:m1:0",
    "receipt:m1",
    "agents:m1",
    "part:m2:0",
    "status",
  ]);
  expect(withExtras(rows, undefined)).toBe(rows);
});

const { MessagesTranscript } = await import("../src/pages/home-messages/transcript/MessagesTranscript");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;

const chiefChat: HomeConversation = {
  id: "c1",
  owner: "local",
  title: "Chief",
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
const twoMessages: HomeMessage[] = ["me", "chief"].map((author, index) => ({
  id: `m${index}`,
  conversation: "c1",
  seq: index + 1,
  author,
  createdAt: 1_700_000_000_000 + index * 1000,
  retracted: false,
  parts: [{ type: "text", text: `message ${index}`, mentions: [] }],
  reactions: [],
}));

test("a toast over the message box takes room under the newest message, and gives it back", async () => {
  const container = installDom();
  // The toast measures 40 px; the observer reports at once.
  Object.defineProperty(dom!.window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("mt-toast-room") ? 40 : 0;
    },
  });
  scope.ResizeObserver = class {
    constructor(private readonly run: (entries: unknown[]) => void) {}
    observe() {
      this.run([]);
    }
    unobserve() {}
    disconnect() {}
  };
  const render = (toast?: string) =>
    root!.render(
      <MessagesTranscript
        strings={strings}
        me="me"
        conversation={chiefChat}
        messages={twoMessages}
        connection="online"
        onSend={async () => true}
        onLoadOlder={() => {}}
        now={1_700_000_010_000}
        {...(toast ? { toast: <span>{toast}</span> } : {})}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    render("Stopped all agents: a1");
  });
  await settle();
  expect(container.querySelector(".mt-compose .mt-toast-room")?.textContent).toBe("Stopped all agents: a1");
  const keys = () => [...container.querySelectorAll<HTMLElement>(".mt-slot")].map((slot) => slot.dataset.key);
  expect(keys().at(-1)).toBe("toast-room");
  await act(async () => render());
  await settle();
  expect(keys()).not.toContain("toast-room");
});

const { TurnSteps, statusParts, turnDetails, stepsSummary } =
  await import("../src/pages/home-messages/transcript/turnSteps");
const { newestActivity, ChiefStatusLine } = await import("../src/pages/home-messages/transcript/ChiefStatusLine");

test("the status line folds the turn's finished steps and counts the running one", () => {
  const steps = new TurnSteps();
  const t0 = 1_700_000_000_000;
  steps.record({ line: "Running git log", since: t0 });
  steps.record({ line: "Running ls", since: t0 + 2000 });
  // The same start with a sharper line stays one step.
  steps.record({ line: "Reading", since: t0 + 3000 });
  steps.record({ line: "Reading notes.md", since: t0 + 3000 });
  steps.record({ line: "Checking on a31", since: t0 + 5000 });
  expect(steps.steps.map((step) => step.line)).toEqual([
    "Running git log",
    "Running ls",
    "Reading notes.md",
    "Checking on a31",
  ]);
  expect(statusParts(steps, { line: "Checking on a31", since: t0 + 5000 }, t0 + 135_000, strings)).toEqual([
    "Ran 2 commands · Reading notes.md ›",
    "Checking on a31 · 2m 10s",
  ]);
  const details = turnDetails(steps, t0 + 135_000, strings);
  expect(details.total).toBe("Total 2m 15s");
  expect(details.rows.map((row) => `${row.line} ${row.duration}`)).toEqual([
    "Running git log 2s",
    "Running ls 1s",
    "Reading notes.md 2s",
    "Checking on a31 now",
  ]);
  // An older clock is a new run: the record starts over.
  steps.record({ line: "Thinking", since: t0 - 1 });
  expect(steps.steps).toHaveLength(1);
});

test("several generic steps are never counted, and the model's own lines are no steps", () => {
  expect(stepsSummary(["Thinking", "Writing the reply"], strings)).toBeUndefined();
  expect(stepsSummary(["Telling a1", "Checking on a2"], strings)).toBeUndefined();
  expect(stepsSummary(["Telling a1"], strings)).toBe("Telling a1 ›");
});

test("the line follows the newest run that still runs", () => {
  const lives = [
    { conversation: "c1", author: "chief", run: "r1", steps: [], activity: { line: "Old", since: 1, at: 1 } },
    {
      conversation: "c1",
      author: "chief",
      run: "r2",
      steps: [],
      activity: { line: "Editing app.ts", since: 2, at: 2 },
    },
  ];
  expect(newestActivity(lives, [{ id: "r1", author: "chief" }])?.activity.line).toBe("Old");
  expect(newestActivity(lives, [{ id: "r2", author: "chief" }])?.run).toBe("r2");
  expect(newestActivity(lives, [])).toBeUndefined();
});

test("the status line draws its parts and names its steps list", async () => {
  const container = installDom();
  const steps = new TurnSteps();
  const now = Date.now();
  steps.record({ line: "Running ls", since: now - 5000 });
  steps.record({ line: "Running pwd", since: now - 4000 });
  steps.record({ line: "Editing app.ts", since: now - 3000 });
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChiefStatusLine
        activity={{ run: "r1", author: "chief", activity: { line: "Editing app.ts", since: now - 3000 } }}
        steps={steps}
        strings={strings}
      />,
    );
  });
  const line = container.querySelector<HTMLButtonElement>(".mt-chief-status-line")!;
  expect(line.title).toBe("Show This Turn's Steps");
  expect([...line.querySelectorAll(".mt-chief-status-part")].map((part) => part.textContent)).toEqual([
    "Ran 2 commands ›",
    "Editing app.ts · 3s",
  ]);
});

// Agent pills (HomeAgentRunMapping, HomeAgentMessages); Home never splits, so no agent pane.
const { agentMessages, agentRows, agentWorkspaceLink, taskTitle, workspaceLink } =
  await import("../src/pages/home-messages/cards/pills/agentRuns");
const { useAgents, windowEntries } = await import("../src/pages/home-messages/cards/pills/useAgents");
const { cardStrings } = await import("../src/pages/home-messages/cards/strings");
type HomeRunStep = import("../src/pages/home-channels/types").HomeRunStep;
type RunEntry = import("../src/pages/home-channels/runs").RunEntry;

const toolStep = (
  id: string,
  seq: number,
  at: number,
  tool: Partial<NonNullable<HomeRunStep["tool"]>>,
  status?: "failed",
) =>
  ({
    id,
    seq,
    at,
    rev: 1,
    kind: "tool",
    ...(status ? { status } : {}),
    tool: { name: "spawn", files: [], ...tool },
    attachments: [],
    links: [],
  }) as HomeRunStep;
const noteStep = (id: string, seq: number, at: number, text: string) =>
  ({ id, seq, at, rev: 1, kind: "note", text, attachments: [], links: [] }) as unknown as HomeRunStep;
const homeMessage = (fields: Partial<HomeMessage> & { id: string; seq: number; author: string; text?: string }) =>
  ({
    conversation: "c1",
    createdAt: fields.seq * 1000,
    retracted: false,
    reactions: [],
    ...fields,
    parts: [{ type: "text", text: fields.text ?? "", mentions: [] }],
  }) as unknown as HomeMessage;
const runEntry = (id: string, turn: string, steps: HomeRunStep[], answers: string[] = []): RunEntry =>
  ({
    run: {
      id,
      conversation: "c1",
      author: "chief",
      status: "done",
      startedAt: 1,
      updatedAt: 1,
      rev: 1,
      stepCount: steps.length,
      turn,
      answers,
    },
    steps,
    complete: true,
  }) as unknown as RunEntry;

const spawnStep = toolStep("s1", 1, 100, {
  name: "mcp__optchat__spawn",
  input: { tasks: ["Title: Fix the login\nLook at auth.ts", "Write tests, then run them"] },
  output: "spawned:\n- a1: started\n- a2: queued",
});

test("a run's spawn, tell and report steps are the Chief's messages with its agents", () => {
  const steps = [
    spawnStep,
    toolStep("t1", 2, 200, {
      name: "tell",
      input: { id: "a1", message: "also check logout" },
      output: "outcome: refused",
    }),
    // Codex wraps an MCP call in an envelope.
    toolStep("t2", 3, 300, {
      name: "mcp_tool_call",
      input: { server: "optchat", tool: "tell", arguments: { id: "a2", message: "go" } },
      output: "outcome: queued",
    }),
    noteStep("report:a1", 4, 400, "[a1] Fixed it."),
  ];
  const messages = agentMessages(steps, 0);
  expect(messages.map((m) => [m.peer, m.outgoing, m.text, m.queued])).toEqual([
    ["a1", true, "Title: Fix the login\nLook at auth.ts", false],
    ["a2", true, "Write tests, then run them", true],
    ["a1", true, "also check logout\n[Error: outcome: refused]", false],
    ["a2", true, "go", true],
    ["a1", false, "Fixed it.", false],
  ]);
  // A spawn whose ids do not match its tasks names no one.
  expect(agentMessages([toolStep("s", 1, 1, { input: { tasks: ["x", "y"] }, output: "- a1: started" })], 0)).toEqual(
    [],
  );
  expect(taskTitle("Write tests, then run them")).toBe("Write tests");
  expect(taskTitle('User (Nov 4): "Fix the dock icon"')).toBe("Fix the dock icon");
});

test("one pill per agent, in the row of its newest message, under the turn's own message", () => {
  // The Chief's own `send` in turn 1 carries its pills (not its reply after it).
  const ask = homeMessage({ id: "m1", seq: 1, author: "chief", clientMessageId: "send-c1-turn1-0123456789abcdef" });
  const reply1 = homeMessage({ id: "m2", seq: 2, author: "chief", clientMessageId: "turn1" });
  const ask2 = homeMessage({ id: "m3", seq: 3, author: "me" });
  const reply2 = homeMessage({ id: "m4", seq: 4, author: "chief", clientMessageId: "turn2" });
  const first = runEntry("r1", "turn1", [spawnStep]);
  const second = runEntry("r2", "turn2", [noteStep("report:a1", 5, 500, "[a1] Done.")], ["m3"]);
  const rows = agentRows([ask, reply1, ask2, reply2], [first, second]);
  // The turn's send anchors turn 1; turn 2 has no send, so the message it answered.
  expect([...rows.keys()]).toEqual(["m1", "m3"]);
  expect(rows.get("m1")).toEqual({ peers: ["a2"], titles: ["Write tests"], states: ["queued"], unread: [false] });
  expect(rows.get("m3")).toEqual({ peers: ["a1"], titles: ["Fix the login"], states: ["reported"], unread: [true] });
  // Opened: its dot clears until a newer report.
  expect(agentRows([ask, reply1, ask2, reply2], [first, second], new Map([["a1", 500]])).get("m3")?.unread).toEqual([
    false,
  ]);
  // A run whose messages are not loaded has no row.
  expect(agentRows([ask2], [first]).size).toBe(0);
  // Two sends in the turn: a pill goes beside the one that names its agent.
  const said1 = homeMessage({
    id: "s1",
    seq: 1,
    author: "chief",
    clientMessageId: "send-c1-turn1-0123456789abcdef",
    text: "On it.",
  });
  const said2 = homeMessage({
    id: "s2",
    seq: 2,
    author: "chief",
    clientMessageId: "send-c1-turn1-fedcba9876543210",
    text: "a2 writes tests (not a20)",
  });
  expect([...agentRows([said1, said2], [first])].map(([anchor, row]) => [anchor, row.peers])).toEqual([
    ["s1", ["a1"]],
    ["s2", ["a2"]],
  ]);
  // A status note is Stopped.
  const stopped = runEntry("r3", "turn2", [noteStep("report:a1", 6, 600, "[a1] (gone: deleted)")], ["m3"]);
  expect(agentRows([ask2], [stopped]).get("m3")?.states).toEqual(["stopped"]);
});

test("a pill's target is the Chief's link to the agent's session, never one of mine", () => {
  const link = "cmux://chief/0123abcd/session/sess-1";
  const messages = [
    homeMessage({ id: "n1", seq: 4, author: "me", text: "[a1](cmux://chief/0123abcd/session/mine)" }),
    homeMessage({ id: "c1", seq: 6, author: "chief", text: `Started [a1](${link}) on it.` }),
  ];
  expect(agentWorkspaceLink("a1", messages, "me")).toBe(link);
  expect(agentWorkspaceLink("a2", messages, "me")).toBeUndefined();
  expect(workspaceLink("a1", ["[a1](cmux://chief/zz/session/x)"])).toBeUndefined();
});

function fakeAgentStore(entries: RunEntry[]) {
  const sent: string[] = [];
  const loads: string[] = [];
  const store = {
    runs: {
      subscribe: () => () => {},
      getVersion: () => 0,
      forReply: (m: HomeMessage) => entries.find((e) => e.run.turn === m.clientMessageId),
      liveFor: (m: HomeMessage) => entries.filter((e) => e.run.answers.includes(m.id)),
    },
    loadRunSteps: async (run: { id: string }) => void loads.push(run.id),
    send: async (text: string) => {
      sent.push(text);
      return true;
    },
  };
  return { store: store as never, sent, loads };
}

function AgentsHarness(props: {
  store: never;
  messages: HomeMessage[];
  openOutside?: (link: string) => boolean;
  startAgent?: (peer: string) => Promise<boolean>;
}) {
  const view = useAgents(
    props.store,
    props.messages,
    "me",
    props.openOutside,
    cardStrings(["en"]),
    true,
    props.startAgent,
  );
  return (
    <div>
      {view.card}
      {[...view.after].map(([anchor, extras]) => (
        <div key={anchor} data-anchor={anchor}>
          {extras.map((extra) => (
            <div key={extra.key}>{extra.node}</div>
          ))}
        </div>
      ))}
    </div>
  );
}

test("a pill opens its agent's workspace right of Home through the host; with no link it opens nothing else", async () => {
  const link = "cmux://chief/0123abcd/session/sess-1";
  const ask = homeMessage({ id: "m1", seq: 1, author: "chief", clientMessageId: "send-c1-turn1-0123456789abcdef" });
  const reply = homeMessage({ id: "m2", seq: 2, author: "chief", clientMessageId: "turn1", text: `[a1](${link})` });
  const entry = runEntry("r1", "turn1", [spawnStep]);
  const pending = { ...runEntry("r2", "turn9", []), complete: false } as RunEntry;
  (pending.run as { stepCount: number }).stepCount = 3;
  (pending.run as { answers: string[] }).answers = ["m2"];
  const { store, sent, loads } = fakeAgentStore([entry, pending]);
  expect(windowEntries((store as { runs: never }).runs, [ask, reply])).toEqual([entry, pending]);
  const opened: string[] = [];
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AgentsHarness store={store} messages={[ask, reply]} openOutside={(url) => (opened.push(url), true)} />,
    );
  });
  // A run without its steps is read for the rows.
  expect(loads).toEqual(["r2"]);
  const pills = () => [...container.querySelectorAll<HTMLButtonElement>("[data-anchor=m1] .hm-pill")];
  expect(pills().length).toBe(2);
  await act(async () => pills()[0]!.click());
  expect(opened).toEqual([link]);
  // a2 has no link (no workspace yet): nothing opens, and Home never splits.
  await act(async () => pills()[1]!.click());
  expect(opened).toEqual([link]);
  expect(container.querySelector(".hm-agent-pane")).toBeNull();
  expect(sent).toEqual([]);
});

test("a queued agent's pill with no link shows its card, and Start now asks the Chief to start it", async () => {
  // User 2026-11-08: "a queued agent's pill must never do nothing on a click".
  const ask = homeMessage({ id: "m1", seq: 1, author: "chief", clientMessageId: "send-c1-turn1-0123456789abcdef" });
  const reply = homeMessage({ id: "m2", seq: 2, author: "chief", clientMessageId: "turn1", text: "On it." });
  const { store } = fakeAgentStore([runEntry("r1", "turn1", [spawnStep])]);
  const started: string[] = [];
  let answer = false;
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AgentsHarness
        store={store}
        messages={[ask, reply]}
        openOutside={() => true}
        startAgent={async (peer) => (started.push(peer), answer)}
      />,
    );
  });
  const pills = () => [...container.querySelectorAll<HTMLButtonElement>("[data-anchor=m1] .hm-pill")];
  await act(async () => pills()[1]!.click());
  // The ui/ Popover portals the card out of the transcript.
  const card = () => document.querySelector<HTMLElement>(".hm-pill-card");
  expect(card()?.querySelector(".hm-pill-card__status")?.textContent).toBe("Starts next");
  const start = () => card()!.querySelector<HTMLButtonElement>(".hm-pill-card__start")!;
  expect(start().textContent).toBe("Start now");
  // A refused start keeps the card and its button.
  await act(async () => start().click());
  await settle();
  expect(started).toEqual(["a2"]);
  expect(start().disabled).toBe(false);
  answer = true;
  await act(async () => start().click());
  await settle();
  expect(started).toEqual(["a2", "a2"]);
  expect(card()).toBeNull();
  // Escape closes a card.
  await act(async () => pills()[1]!.click());
  expect(card()).not.toBeNull();
  await act(async () => {
    document.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(card()).toBeNull();
  // The queued pill's menu has Start now.
  const menuItems = () => [...document.querySelectorAll('[role="menuitem"]')].map((item) => item.textContent);
  await act(async () => {
    pills()[1]!.dispatchEvent(new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
  });
  expect(menuItems()).toEqual(["Start now"]);
  await act(async () => document.querySelector<HTMLElement>('[role="menuitem"]')!.click());
  await settle();
  expect(started).toEqual(["a2", "a2", "a2"]);
});
