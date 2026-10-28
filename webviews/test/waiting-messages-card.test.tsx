// l10n-allow-file: test fixture chat names and messages, not shipped UI.
// Several other sessions' messages that wait for the agent draw as one card, not one card each
// (conversation/waitingMessages.ts, WaitingMessagesCard.tsx; Leo, 2026-10-27: "i also feel like
// there should be better batching for messages from other sessions so you can get to things
// faster/more efficiently"). Steered in and unread ("Read after this step") or queued behind the
// turn ("Read after this turn"), never mixed; open, each message is its own received card with its
// own actions, oldest first. One message alone draws as before.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { CHAT, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  Range: dom.window.Range,
  CustomEvent: dom.window.CustomEvent,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { queuedMessageRows } = await import("../src/agent-session/acpmux/conversation/queuedMessages");
const waitingModule = "../src/agent-session/acpmux/conversation/waitingMessages";

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// Another session's message steered into the running turn, as acpmux records it.
const steer = (promptId: string, from: string, text: string): Step => [
  "mux",
  "user_message",
  {
    promptId,
    text,
    steer: true,
    _meta: { provenance: { kind: "session_message", from: `acp:s-${from}`, fromName: from } },
  },
];

async function connect(steps: Step[]) {
  const daemon = fakeDaemon(record(steps));
  let snapshot: AcpmuxSnapshot | undefined;
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return snapshot!;
}

const doc = dom.window.document;
const root = createRoot(doc.getElementById("root")!);
async function draw(props: { rows: AcpmuxRow[]; queuedTail?: readonly AcpmuxRow[]; waitingSteers?: readonly string[] }) {
  // On a page without the card the prop is only ignored: the test then reads N cards.
  const Transcript = VirtualTranscript as (props: Record<string, unknown>) => React.ReactElement;
  await act(async () => root.render(<Transcript {...props} onToggleActivity={() => {}} expanded={new Set()} />));
}
const click = (element: Element) =>
  act(async () => {
    element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
const received = () => [...doc.querySelectorAll<HTMLElement>(".cv-received")];

test("three steered messages from two sessions are one card; open, each is its received card in order", async () => {
  const snapshot = await connect([
    ["mux", "user_message", { promptId: "p-turn", text: "Add retries" }],
    steer("p-1", "lane-a", "First: CI is green on #24210."),
    steer("p-2", "lane-b", "Second: review passed on #24214."),
    steer("p-3", "lane-a", "Third: rebase before you push."),
  ]);
  await draw({ rows: snapshot.rows, waitingSteers: snapshot.waitingSteers });
  const cards = [...doc.querySelectorAll<HTMLElement>(".cv-waiting")];
  expect(cards).toHaveLength(1);
  const card = cards[0]!;
  expect(card.dataset.delivery).toBe("step");
  expect(card.querySelector(".cv-waiting__count")?.textContent).toBe(
    translate("message.waitingFrom", { n: 3, sessions: 2 }),
  );
  expect([...card.querySelectorAll(".cv-waiting__sender")].map((name) => name.textContent)).toEqual([
    "lane-a",
    "lane-b",
  ]);
  expect(card.querySelector(".cv-received__queued")?.textContent).toBe(translate("message.readAfterStep"));
  // Closed, no message draws on its own.
  expect(received()).toHaveLength(0);

  const toggle = card.querySelector<HTMLButtonElement>(".cv-waiting__toggle")!;
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  await click(toggle);
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  const messages = received();
  expect(messages.map((message) => message.closest(".cv-waiting"))).toEqual([card, card, card]);
  expect(messages.map((message) => message.textContent)).toEqual([
    expect.stringContaining("First: CI is green"),
    expect.stringContaining("Second: review passed"),
    expect.stringContaining("Third: rebase"),
  ]);
  // Each keeps its own delivery note and its own actions.
  for (const message of messages)
    expect(message.querySelector(".cv-received__queued")?.textContent).toBe(translate("message.readAfterStep"));
  await click(toggle);
  expect(received()).toHaveLength(0);
});

test("one steered message alone draws as before", async () => {
  const snapshot = await connect([
    ["mux", "user_message", { promptId: "p-turn", text: "Add retries" }],
    steer("p-1", "lane-a", "Only: CI is green on #24210."),
  ]);
  expect(snapshot.waitingSteers).toBeUndefined();
  await draw({ rows: snapshot.rows, waitingSteers: snapshot.waitingSteers });
  expect(doc.querySelector(".cv-waiting")).toBeNull();
  expect(received()).toHaveLength(1);
});

const queuedAgent = (index: number) => {
  const text = `Lane ${index}: CI is green on #${24000 + index}.`;
  return { id: `a${index}`, prompt: text, message: { name: `lane-${index}`, sessionId: `s-${index}`, text, raw: text } };
};

test("messages queued behind the turn are one card that opens to their queued cards", async () => {
  const snapshot = await connect([["mux", "user_message", { promptId: "p-turn", text: "Add retries" }]]);
  const tail = queuedMessageRows([1, 2, 3, 4].map(queuedAgent) as never, undefined);
  await draw({ rows: [...snapshot.rows, ...tail], queuedTail: tail });
  const cards = [...doc.querySelectorAll<HTMLElement>(".cv-waiting")];
  expect(cards).toHaveLength(1);
  expect(cards[0]!.dataset.delivery).toBe("turn");
  expect(cards[0]!.querySelector(".cv-waiting__count")?.textContent).toBe(
    translate("message.waitingFrom", { n: 4, sessions: 4 }),
  );
  expect(received()).toHaveLength(0);
  await click(cards[0]!.querySelector(".cv-waiting__toggle")!);
  expect(received().map((message) => message.textContent)).toEqual(
    [1, 2, 3, 4].map((index) => expect.stringContaining(`Lane ${index}: CI is green`)),
  );
  // Each still has its own ⋯ menu.
  expect(cards[0]!.querySelectorAll('[data-menu="queued-message"]')).toHaveLength(4);
});

test("grouping: runs of two or more of one kind, never mixed, and nothing changes without one", async () => {
  const { groupWaitingMessages } = await import(waitingModule);
  const row = (id: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({ id, version: 1, at: 0, kind: "user", ...fields });
  const message = (id: string, name: string): AcpmuxRow =>
    row(id, {
      steer: "waiting",
      untyped: true,
      incoming: { kind: "message", message: { name, sessionId: name, text: id, raw: id } },
    });
  const own = row("own", { steer: "waiting", text: "mine" });
  const rows = [
    row("summary", { kind: "turnSummary" }),
    row("turn"),
    message("m1", "a"),
    message("m2", "b"),
    own,
    message("m3", "a"),
    message("m4", "c"),
    message("m5", "c"),
  ];
  // Fewer than two steers waiting and no queued tail: the same rows.
  const none = groupWaitingMessages(rows, undefined, ["m1"]);
  expect(none.rows).toBe(rows);
  const steers = ["m1", "m2", "own", "m3", "m4", "m5"];
  const grouped = groupWaitingMessages(rows, undefined, steers);
  expect(grouped.rows.map((r: AcpmuxRow) => r.id)).toEqual(["summary", "turn", "waiting-step-m1", "own", "waiting-step-m3"]);
  expect(grouped.rows[2].waiting.rows.map((r: AcpmuxRow) => r.id)).toEqual(["m1", "m2"]);
  expect(grouped.rows[4].waiting.rows.map((r: AcpmuxRow) => r.id)).toEqual(["m3", "m4", "m5"]);
  expect(grouped.rows[4].joined).toEqual(["m3", "m4", "m5"]);
  // The same rows again keep the same card rows.
  const again = groupWaitingMessages([...rows], undefined, steers, grouped);
  expect(again.rows[2]).toBe(grouped.rows[2]);
  expect(again.rows[4]).toBe(grouped.rows[4]);
  // A steer before the running turn's start is not looked for.
  const old = [message("o1", "a"), message("o2", "b"), row("summary", { kind: "turnSummary" }), row("turn")];
  expect(groupWaitingMessages(old, undefined, ["o1", "o2"]).rows).toBe(old);

  // The queued tail: one card, after the steers' card, never one card of both.
  const tail = queuedMessageRows([1, 2].map(queuedAgent) as never, undefined);
  const both = groupWaitingMessages([...rows, ...tail], tail, steers);
  expect(both.rows.map((r: AcpmuxRow) => r.id)).toEqual([
    "summary",
    "turn",
    "waiting-step-m1",
    "own",
    "waiting-step-m3",
    "waiting-turn",
  ]);
  expect(both.tail.map((r: AcpmuxRow) => r.id)).toEqual(["waiting-turn"]);
  expect(both.tail[0].waiting).toEqual({ delivery: "turn", rows: tail });
  // One queued message alone stays as it is.
  const one = queuedMessageRows([queuedAgent(1)] as never, undefined);
  const single = [...rows.slice(0, 2), ...one];
  const alone = groupWaitingMessages(single, one, undefined);
  expect(alone.rows).toBe(single);
  expect(alone.tail).toBe(one);
});
