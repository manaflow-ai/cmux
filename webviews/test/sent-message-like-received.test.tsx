// l10n-allow-file: test fixtures.
// A message this agent sent another one draws as a received message does (ask-64e107ccf0; Leo,
// 2026-11-07, on a "Sent to" row with its Raw open on a heavy Shell card, under a received message:
// "Did we not fix this formatting yet? Um, like the raw thing? This is just weird. This, I mean,
// yeah, it's just not good, compared to the normal ones."): the same line (the mark, the other
// agent's chip, its machine after it, the first line muted) and the same opened card. Raw is closed
// by default, stays closed when the row is drawn again or Find opens the message, and opened it is
// the call's plain command row, never a Shell card.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { AcpmuxSendLine } = await import("../src/agent-session/acpmux/conversation/SentMessageLine");
const { configureSentLook } = await import("../src/agent-session/acpmux/conversation/sentMessageLineModel");
const { acpmuxSendCall } = await import("../src/agent-session/acpmux/conversation/acpmuxSends");
const { FindReveal, activityText, foldFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { resetTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

beforeEach(() => resetTranscriptDisclosure());
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Leo's row: a coordinator's `acpmux send` to a lane on another machine, its output cut to the
/// daemon's one line.
const leoSend: Tool = {
  id: "toolu_leo_send",
  title: "acpmux send build-box/acpmux-client-rust-2 …",
  kind: "execute",
  status: "completed",
  command: `acpmux send build-box/acpmux-client-rust-2 'coord: the old lane'"'"'s handoff is yours now. Rebase on feat-cmux-next first.' 2>&1|tail -1`,
  output: "queued (delivery 01a1b65e-7c1d-7e2a-9f00-3b5a2c1d0e9f)",
  exitCode: 0,
};

async function draw(node: ReactNode) {
  root ??= createRoot(host);
  const store = new SubsessionStore();
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>{node}</SubsessionContext.Provider>,
    ),
  );
}

const sentLine = (tool: Tool = leoSend) => <AcpmuxSendLine tool={tool} send={acpmuxSendCall(tool)!} />;

const receivedLine = () => (
  <IncomingMessageLine
    id="row-received"
    message={{
      name: "dev-box/acpmux-client-rust",
      text: "Rebased; ready for review.",
      raw: "<cmux-message from=acpmux-client-rust>\nRebased; ready for review.\n</cmux-message>",
    }}
    onOpen={() => undefined}
  />
);

/// The parts a message row is made of, in the order they draw, closed and opened.
function shape(): string[] {
  const row = host.querySelector<HTMLElement>(".cv-agentmsg")!;
  const parts = (selectors: string[]) => selectors.filter((selector) => row.querySelector(`:scope ${selector}`));
  // Both draw as the one message row (AgentMessageRow.tsx): the mark in its icon column, the chip in
  // the sender span, the first line in the toggle; opened, the card, then Details or Raw under it.
  const closed = parts([
    "> .cv-agentmsg__line",
    "> .cv-agentmsg__line > .cv-agentmsg__icon > .cv-received__mark",
    "> .cv-agentmsg__line > .cv-agentmsg__sentence > .cv-received__sender > .cv-agent-tag",
    "> .cv-agentmsg__line .cv-agentmsg__toggle .cv-received__preview",
    "> .cv-agentmsg__line .cv-agentmsg__toggle[aria-expanded=false]",
  ]);
  act(() => row.querySelector<HTMLElement>(".cv-agentmsg__toggle")!.click());
  const opened = parts([
    "> .cv-agentmsg__line .cv-agentmsg__toggle[aria-expanded=true]",
    ".cv-agentmsg__card > .cv-received__text .cv-md",
    ".cv-agentmsg__open > .cv-received__details > button.cv-received__more[aria-expanded=false]",
  ]);
  return [row.classList.contains("cv-received") ? "cv-received" : "other", ...closed, ...opened];
}

test("an outgoing message row has the incoming row's header and body", async () => {
  await draw(receivedLine());
  const received = shape();
  act(() => root?.unmount());
  root = undefined;
  await draw(sentLine());
  const sent = shape();
  expect(received).toHaveLength(9);
  expect(sent).toEqual(received);
  // Direction is the label's: "Sent to" before the recipient, and the machine after its name as a
  // received message's sender names it.
  const sender = host.querySelector(".cv-received__sender")!;
  expect(sender.textContent).toContain("Sent to");
  expect(sender.querySelector(".cv-agent-tag")!.textContent).toBe("acpmux-client-rust-2");
  expect(sender.querySelector(".cv-received__host")?.textContent).toBe("build-box");
  expect(host.querySelector(".cv-received__text")!.textContent).toContain("handoff is yours now");
});

test("Raw is closed by default and stays closed when the row is drawn again", async () => {
  await draw(sentLine());
  act(() => host.querySelector<HTMLElement>(".cv-agentmsg__toggle")!.click());
  const raw = () => host.querySelector<HTMLButtonElement>(".cv-received__details > .cv-received__more");
  expect(raw()!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector("[data-tool-id], .cv-shell")).toBeNull();
  // The reader opens Raw, then the row scrolls out of the virtualized transcript and back (or the
  // page reloads): the message keeps its saved open state, Raw starts closed again.
  act(() => raw()!.click());
  expect(raw()!.getAttribute("aria-expanded")).toBe("true");
  act(() => root?.unmount());
  root = undefined;
  await draw(sentLine());
  expect(host.querySelector(".cv-agentmsg__toggle")!.getAttribute("aria-expanded")).toBe("true");
  expect(raw()!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector("[data-tool-id], .cv-shell")).toBeNull();
});

test("Find opens the message to its words, not its Raw", async () => {
  // A match in the message (and so in the command line that carries it) opened both the row and
  // its Raw on every send whose call held it, and Raw stayed open after Find closed.
  const reveal = { rowId: "row-1", card: false, needle: "handoff", repaint: () => undefined };
  await draw(<FindReveal.Provider value={reveal}>{sentLine()}</FindReveal.Provider>);
  expect(host.querySelector(".cv-agentmsg__toggle")!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__more")!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector("[data-tool-id], .cv-shell")).toBeNull();
});

test("Find opens Raw for a match only in a link's address, which the message does not show", async () => {
  // The message draws "report"; its Markdown source holds the address. Kept shut, Raw would hide
  // the only place Find can show the match.
  const linked: Tool = {
    ...leoSend,
    id: "toolu_linked_send",
    command: "acpmux send build-box/acpmux-client-rust-2 'See [report](https://example.com/results).' 2>&1|tail -1",
  };
  const reveal = { rowId: "row-1", card: false, needle: "example.com/results", repaint: () => undefined };
  await draw(<FindReveal.Provider value={reveal}>{sentLine(linked)}</FindReveal.Provider>);
  expect(host.querySelector(".cv-received__more")!.getAttribute("aria-expanded")).toBe("true");
});

test("Find opens Raw for a match in the output as well as the message, and shows the output", async () => {
  // `acpmux send lane 'ready'` whose reply says "ready" too: Find counts two matches in the call,
  // one in the message and one in the output. Raw stayed shut because the message held the word,
  // so Next went back to the message and never showed the output's match (cmux#37879 review).
  const ready: Tool = {
    id: "toolu_ready_send",
    title: "acpmux send lane …",
    kind: "execute",
    status: "completed",
    command: "acpmux send lane 'ready'",
    output: "lane: ready for the next item",
    exitCode: 0,
  };
  const item: AcpmuxActivity = { kind: "tool", text: ready.title, tool: ready };
  expect(foldFind(activityText(item)).split("ready").length - 1).toBe(2);
  const first = { rowId: "row-1", card: false, needle: "ready", repaint: () => undefined };
  await draw(<FindReveal.Provider value={first}>{sentLine(ready)}</FindReveal.Provider>);
  expect(host.querySelector(".cv-agentmsg__toggle")!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__text")!.textContent).toContain("ready");
  // Next: the same row, its second match. Raw is open and its call shows the output's words.
  const second = { ...first };
  await draw(<FindReveal.Provider value={second}>{sentLine(ready)}</FindReveal.Provider>);
  expect(host.querySelector(".cv-received__more")!.getAttribute("aria-expanded")).toBe("true");
  const raw = host.querySelector<HTMLElement>(".cv-received__details .cv-sent__raw-body, .cv-sent__raw-body");
  expect(raw?.textContent).toContain("ready for the next item");
});

test("a command link to the send call opens its Raw, where the call is", async () => {
  // A command or deep link names the call by id and carries no words: the call draws only behind
  // Raw, so a closed Raw left the link pointing at nothing.
  const reveal = { rowId: "row-1", card: false, needle: "", toolId: leoSend.id, repaint: () => undefined };
  await draw(<FindReveal.Provider value={reveal}>{sentLine()}</FindReveal.Provider>);
  expect(host.querySelector(".cv-received__more")!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(`.cv-received__details [data-tool-id="${leoSend.id}"]`)).not.toBeNull();
});

test("the arrow look names the message's first line once", async () => {
  configureSentLook("arrow");
  try {
    await draw(sentLine());
    const line = host.querySelector(".cv-agentmsg__line")!.textContent ?? "";
    expect(line.split("the old lane").length - 1).toBe(1);
  } finally {
    configureSentLook("sentence");
  }
});

test("opened, Raw is the call's plain command row, with no Shell card", async () => {
  await draw(sentLine());
  act(() => host.querySelector<HTMLElement>(".cv-agentmsg__toggle")!.click());
  act(() => host.querySelector<HTMLElement>(".cv-received__more")!.click());
  const command = host.querySelector<HTMLElement>(".cv-received__details .cv-tool[data-tool-id]");
  expect(command?.dataset.toolId).toBe(leoSend.id);
  expect(command!.textContent).toContain("acpmux send");
  expect(host.querySelector(".cv-shell")).toBeNull();
});
