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

const { act, useContext } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { queuedMessageRows } = await import("../src/agent-session/acpmux/conversation/queuedMessages");
const { turnViewFrom } = await import("../src/agent-session/acpmux/conversation/turns");
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
/// The chat's rows as the pane draws them (turns.ts), the steers that wait among them.
const drawn = (snapshot: AcpmuxSnapshot) =>
  // On a page without the card the option is only ignored: the test then reads N cards.
  turnViewFrom(snapshot.rows, new Set(), { working: true, waitingSteers: snapshot.waitingSteers } as never).rows;
async function draw(props: { rows: AcpmuxRow[]; queuedTail?: readonly AcpmuxRow[] }) {
  await act(async () => root.render(<VirtualTranscript {...props} onToggleActivity={() => {}} expanded={new Set()} />));
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
  await draw({ rows: drawn(snapshot) });
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
  // No Copy of its own over the note: each message has its own.
  expect(card.closest("[data-floating-copy]")).toBeNull();
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
  await draw({ rows: drawn(snapshot) });
  expect(doc.querySelector(".cv-waiting")).toBeNull();
  expect(received()).toHaveLength(1);
});

const queuedAgent = (index: number) => {
  const text = `Lane ${index}: CI is green on #${24000 + index}.`;
  return {
    id: `a${index}`,
    prompt: text,
    message: { name: `lane-${index}`, sessionId: `s-${index}`, text, raw: text },
  };
};

test("messages queued behind the turn are one card that opens to their queued cards", async () => {
  const { groupWaitingTurn } = await import(waitingModule);
  const snapshot = await connect([["mux", "user_message", { promptId: "p-turn", text: "Add retries" }]]);
  const tail = groupWaitingTurn(queuedMessageRows([1, 2, 3, 4].map(queuedAgent) as never, undefined));
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

test("Find opens a closed card when the match is in one of its messages", async () => {
  const { groupWaitingTurn } = await import(waitingModule);
  const { WaitingMessagesCard } = await import("../src/agent-session/acpmux/conversation/WaitingMessagesCard");
  const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const [card] = groupWaitingTurn(queuedMessageRows([5, 6].map(queuedAgent) as never, undefined));
  let repainted = 0;
  const reveal = (rowId: string) => ({
    rowId,
    card: false,
    needle: "lane 6",
    repaint: () => (repainted += 1),
    member: card.waiting!.rows[1]!.id,
  });
  // Each message sees the reveal its own row would: its own id for the one that holds the match.
  const Member = ({ message }: { message: AcpmuxRow }) => {
    const seen = useContext(FindReveal);
    return (
      <p className="member" data-revealed={seen?.rowId === message.id || undefined}>
        {message.text}
      </p>
    );
  };
  const show = (rowId?: string) =>
    act(async () =>
      root.render(
        <FindReveal.Provider value={rowId ? reveal(rowId) : undefined}>
          <WaitingMessagesCard row={card} renderMessage={(message) => <Member message={message} />} />
        </FindReveal.Provider>,
      ),
    );
  await show();
  expect(doc.querySelectorAll(".member")).toHaveLength(0);
  // The transcript names the card's row for a match in it (chatFind.ts findRowIndex).
  await show(card.id);
  expect([...doc.querySelectorAll(".member")].map((member) => member.textContent)).toEqual([
    expect.stringContaining("Lane 5"),
    expect.stringContaining("Lane 6"),
  ]);
  expect(repainted).toBe(1);
  expect([...doc.querySelectorAll<HTMLElement>(".member")].map((member) => member.dataset.revealed)).toEqual([
    undefined,
    "true",
  ]);
  // Find's active match counts in the message's own element.
  expect(
    [...doc.querySelectorAll<HTMLElement>("[data-find-member]")].map((member) => member.dataset.findMember),
  ).toEqual(card.waiting!.rows.map((message) => message.id));
  // The head's names are not Find's text.
  expect(doc.querySelector(".cv-waiting__line")?.hasAttribute("data-find-skip")).toBe(true);
});

test("grouping: runs of two or more of one kind, never mixed, and nothing changes without one", async () => {
  const { groupWaitingSteps, groupWaitingTurn } = await import(waitingModule);
  const { WAITING_MESSAGES } = await import("../src/agent-session/acpmux/model");
  const row = (id: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    version: 1,
    at: 0,
    kind: "user",
    ...fields,
  });
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
  const ids = (list: readonly AcpmuxRow[]) => list.map((r) => r.id);
  const steers = ["m1", "m2", "own", "m3", "m4", "m5"];
  // No run of two: no card.
  expect(groupWaitingSteps(rows, ["m1", "m3"]).runs).toEqual([]);
  const grouped = groupWaitingSteps(rows, steers);
  const runIds = (steps: { runs: readonly (readonly [number, number, AcpmuxRow])[] }) =>
    steps.runs.map(([from, to, card]) => [from, to, card.id, ids(card.waiting!.rows)]);
  expect(runIds(grouped)).toEqual([
    [2, 4, "waiting-step-m1", ["m1", "m2"]],
    [5, 8, "waiting-step-m3", ["m3", "m4", "m5"]],
  ]);
  expect(grouped.runs[1]![2].joined).toEqual(["m3", "m4", "m5"]);
  // A streamed snapshot (a reply after them): each steer found where it was, one lookup each, and
  // the same card rows. Were they looked for, the reply row would be passed first: the lookups
  // read only the steers' own places.
  const streamed = [...rows, row("reply", { kind: "assistant" })];
  const read: number[] = [];
  const watched = new Proxy(streamed, {
    get: (target, key) => {
      if (typeof key === "string" && /^\d+$/.test(key)) read.push(Number(key));
      return Reflect.get(target, key);
    },
  });
  const again = groupWaitingSteps(watched, steers, grouped);
  expect(again.runs.map(([, , card]) => card)).toEqual(grouped.runs.map(([, , card]) => card));
  expect(again.runs[0]![2]).toBe(grouped.runs[0]![2]);
  expect(read.includes(streamed.length - 1)).toBe(false);
  // Rows that moved (one above them): looked for again, found in their new places.
  const moved = groupWaitingSteps([row("older"), ...rows], steers, grouped);
  expect(runIds(moved).map(([from]) => from)).toEqual([3, 6]);
  // A steer the turn does not have stays unseen and is not looked for again while the list holds.
  const missing = [...steers, "gone"];
  const first = groupWaitingSteps(rows, missing);
  expect([...first.unseen]).toEqual(["gone"]);
  read.length = 0;
  expect([...groupWaitingSteps(watched, missing, first).unseen]).toEqual(["gone"]);
  expect(read.includes(streamed.length - 1)).toBe(false);

  // In the drawn turns: only the running turn's steers, and the view is the same while nothing
  // changed; a steer read regroups.
  const chat = [
    row("p0"),
    message("x1", "a"),
    message("x2", "b"),
    row("s0", { kind: "turnSummary" }),
    ...rows.slice(1),
  ];
  const closed = new Set<string>();
  const view = turnViewFrom(chat, closed, { working: true, waitingSteers: steers });
  expect(view.rows.filter((r) => r.kind === WAITING_MESSAGES).map((r) => r.id)).toEqual([
    "waiting-step-m1",
    "waiting-step-m3",
  ]);
  expect(turnViewFrom(chat, closed, { working: true, waitingSteers: steers }, view)).toBe(view);
  const unread = ["m4", "m5"];
  const after = turnViewFrom(chat, closed, { working: true, waitingSteers: unread }, view);
  expect(after.rows.filter((r) => r.kind === WAITING_MESSAGES).map((r) => r.id)).toEqual(["waiting-step-m4"]);
  expect(turnViewFrom(chat, closed, { working: true }, after).rows.some((r) => r.kind === WAITING_MESSAGES)).toBe(
    false,
  );

  // The queued tail: one card, named by its first message, so a later batch never takes its open
  // state; the same rows give the same card back.
  const tail = queuedMessageRows([1, 2].map(queuedAgent) as never, undefined);
  const turn = groupWaitingTurn(tail);
  expect(ids(turn)).toEqual([`waiting-turn-${tail[0]!.id}`]);
  expect(turn[0].waiting).toEqual({ delivery: "turn", rows: tail });
  expect(groupWaitingTurn(tail, turn)).toBe(turn);
  const later = queuedMessageRows([3, 4].map(queuedAgent) as never, undefined);
  expect(groupWaitingTurn(later, turn)[0].id).not.toBe(turn[0].id);
  // One queued message alone stays as it is.
  const one = queuedMessageRows([queuedAgent(1)] as never, undefined);
  expect(groupWaitingTurn(one)).toBe(one);
});
