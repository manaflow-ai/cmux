// An expanded card's corner copy (CardCopy.tsx; Leo, 2026-10-29: "wouldnt it be a little copy symbol
// on the top right within this card?"): it copies the card's raw text, shows a check only when the
// clipboard took it, and goes back to Copy after COPIED_MS. A sub-session's prompt card draws it
// first in its panel, with Raw still at the end.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  Node: dom.window.Node,
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
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// The clipboard takes every write; the copies it got are kept.
const copies: string[] = [];
Object.defineProperty(dom.window.navigator, "clipboard", {
  configurable: true,
  value: { writeText: async (text: string) => void copies.push(text) },
});
// The Copied check's timer runs when the test says so.
type Timer = { run: () => void; ms: number | undefined };
let timers: Timer[] = [];
dom.window.setTimeout = ((run: () => void, ms?: number) => timers.push({ run, ms })) as never;
dom.window.clearTimeout = (() => {}) as never;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { CardCopy, CardCopyLookContext } = await import("../src/agent-session/acpmux/conversation/CardCopy");
const { COPIED_MS } = await import("../src/agent-session/acpmux/conversation/CopyButton");
const { SubsessionCallCard } = await import("../src/agent-session/acpmux/conversation/SubsessionCallCard");
const { subsessionCall } = await import("../src/agent-session/acpmux/conversation/subsessionCalls");
const { TranscriptDisclosureProvider } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

beforeEach(() => {
  copies.length = 0;
  timers = [];
});

const button = () => host.querySelector<HTMLButtonElement>(".cv-card-copy__button")!;
const glyph = (element: Element) => element.querySelector("svg path")?.getAttribute("d");
const copiedTimers = () => timers.filter((timer) => timer.ms === COPIED_MS);

const PROMPT = "Own the **net** lane.\n\n1. Find `RetryBanner`.\n2. Fix it.";

test("the corner copy writes the card's raw text and its check goes back to Copy", async () => {
  await act(async () => root.render(<CardCopy text={PROMPT} />));
  const copy = button();
  const idle = glyph(copy);
  expect([copy.getAttribute("aria-label"), copy.title]).toEqual(["Copy", "Copy"]);
  await act(async () => copy.click());
  // The raw Markdown, as written, not the rendered text.
  expect(copies).toEqual([PROMPT]);
  expect(copy.getAttribute("aria-label")).toBe("Copied");
  expect(copy.hasAttribute("data-copied")).toBe(true);
  expect(glyph(copy)).not.toBe(idle);
  expect(copiedTimers()).toHaveLength(1);
  await act(async () => copiedTimers()[0]!.run());
  expect(copy.getAttribute("aria-label")).toBe("Copy");
  expect(copy.hasAttribute("data-copied")).toBe(false);
  expect(glyph(copy)).toBe(idle);
});

test("a copy the clipboard refused shows no check", async () => {
  await act(async () => root.render(<CardCopy text={PROMPT} copy={async () => false} />));
  await act(async () => button().click());
  expect(button().getAttribute("aria-label")).toBe("Copy");
  expect(copiedTimers()).toHaveLength(0);
});

test("the word look says Copied beside the check; an empty card draws no copy", async () => {
  await act(async () =>
    root.render(
      <CardCopyLookContext.Provider value="word">
        <CardCopy text={PROMPT} />
      </CardCopyLookContext.Provider>,
    ),
  );
  await act(async () => button().click());
  expect(host.querySelector(".cv-copy__word")?.textContent).toBe("Copied");
  await act(async () => root.render(<CardCopy text={"  "} />));
  expect(host.querySelector(".cv-card-copy")).toBeNull();
});

test("a started sub-session's opened card has the corner copy before its prompt, and Raw stays", async () => {
  const tool = {
    id: "start-1",
    title: "mcp__cmux-subsessions__start_session",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ name: "net", prompt: PROMPT }),
    output: "Started sub-session net (sessionId sub-net, depth 1).",
  };
  await act(async () =>
    root.render(
      <TranscriptDisclosureProvider sessionId="card-copy-test">
        <SubsessionCallCard call={subsessionCall(tool)} tool={tool} />
      </TranscriptDisclosureProvider>,
    ),
  );
  const toggle =
    host.querySelector<HTMLButtonElement>(".cv-disclosure__toggle.is-chevron") ??
    host.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!;
  await act(async () => toggle.click());
  const panel = host.querySelector(".cv-disclosure__panel")!;
  expect(panel.firstElementChild?.className).toBe("cv-card-copy");
  expect(panel.querySelector(".cv-subsession__markdown")).not.toBeNull();
  expect([...panel.querySelectorAll("button")].some((one) => one.textContent?.includes("Raw"))).toBe(true);
  await act(async () => button().click());
  expect(copies).toEqual([PROMPT]);
});
