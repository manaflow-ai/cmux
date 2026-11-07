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
const { acpmuxSendCall } = await import("../src/agent-session/acpmux/conversation/acpmuxSends");
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

beforeEach(() => resetTranscriptDisclosure());
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Leo's row: a coordinator's `acpmux send` to a lane on another machine, its output cut to the
/// daemon's one line.
const leoSend: Tool = {
  id: "toolu_leo_send",
  title: "acpmux send gcp-codex-lane-12/acpmux-client-rust-2 …",
  kind: "execute",
  status: "completed",
  command: `acpmux send gcp-codex-lane-12/acpmux-client-rust-2 'coord: the old lane'"'"'s handoff is yours now. Rebase on feat-cmux-next first.' 2>&1|tail -1`,
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
      name: "gcp-codex-swarm-09/acpmux-client-rust",
      text: "Rebased; ready for review.",
      raw: "<cmux-message from=acpmux-client-rust>\nRebased; ready for review.\n</cmux-message>",
    }}
    onOpen={() => undefined}
  />
);

/// The parts a message row is made of, in the order they draw, closed and opened.
function shape(): string[] {
  const row = host.querySelector<HTMLElement>(".cv-disclosure")!;
  const parts = (selectors: string[]) => selectors.filter((selector) => row.querySelector(`:scope ${selector}`));
  const closed = parts([
    "> .cv-disclosure__line",
    "> .cv-disclosure__line > .cv-received__sender > .cv-received__mark",
    "> .cv-disclosure__line > .cv-received__sender > .cv-agent-tag",
    "> .cv-disclosure__line > .cv-disclosure__toggle .cv-received__preview",
    "> .cv-disclosure__line > .cv-disclosure__toggle[aria-expanded=false]",
  ]);
  act(() => row.querySelector<HTMLElement>(".cv-disclosure__toggle")!.click());
  const opened = parts([
    "> .cv-disclosure__line > .cv-disclosure__toggle[aria-expanded=true]",
    ".cv-disclosure__panel > .cv-received__text .cv-md",
    ".cv-disclosure__panel > .cv-received__details > button.cv-received__more[aria-expanded=false]",
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
  expect(sender.querySelector(".cv-received__host")?.textContent).toBe("gcp-codex-lane-12");
  expect(host.querySelector(".cv-received__text")!.textContent).toContain("handoff is yours now");
});

test("Raw is closed by default and stays closed when the row is drawn again", async () => {
  await draw(sentLine());
  act(() => host.querySelector<HTMLElement>(".cv-disclosure__toggle")!.click());
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
  expect(host.querySelector(".cv-disclosure__toggle")!.getAttribute("aria-expanded")).toBe("true");
  expect(raw()!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector("[data-tool-id], .cv-shell")).toBeNull();
});

test("Find opens the message to its words, not its Raw", async () => {
  // A match in the message (and so in the command line that carries it) opened both the row and
  // its Raw on every send whose call held it, and Raw stayed open after Find closed.
  const reveal = { rowId: "row-1", card: false, needle: "handoff", repaint: () => undefined };
  await draw(<FindReveal.Provider value={reveal}>{sentLine()}</FindReveal.Provider>);
  expect(host.querySelector(".cv-disclosure__toggle")!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__more")!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector("[data-tool-id], .cv-shell")).toBeNull();
});

test("opened, Raw is the call's plain command row, with no Shell card", async () => {
  await draw(sentLine());
  act(() => host.querySelector<HTMLElement>(".cv-disclosure__toggle")!.click());
  act(() => host.querySelector<HTMLElement>(".cv-received__more")!.click());
  const command = host.querySelector<HTMLElement>(".cv-received__details .cv-tool[data-tool-id]");
  expect(command?.dataset.toolId).toBe(leoSend.id);
  expect(command!.textContent).toContain("acpmux send");
  expect(host.querySelector(".cv-shell")).toBeNull();
});
