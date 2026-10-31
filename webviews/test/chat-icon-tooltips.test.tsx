// The chat's icon-only buttons say what they do on hover (GUI push 2026-10-21): a prompt's ‹ › version
// arrows, Copy and Edit, and a turn's Copy carry their name as a `title` (the pane's tooltip layer,
// ui/titleTooltips.ts, shows it) as well as their aria-label. A Copy turns into a check that reads
// Copied once the clipboard took the text, and goes back to Copy after a moment; before, a prompt's
// and a turn's Copy kept the copy glyph and said Copied for good.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { COPIED_MS } = await import("../src/agent-session/acpmux/conversation/CopyButton");

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

const named = (selector: string) =>
  [...host.querySelectorAll<HTMLButtonElement>(selector)].map((button) => [
    button.getAttribute("aria-label"),
    button.getAttribute("title"),
  ]);
const copiedTimer = () => timers.find((timer) => timer.ms === COPIED_MS)!;
const glyph = (button: Element) => button.querySelector("svg path")?.getAttribute("d");

const prompt: AcpmuxRow = { id: "user-4", version: 1, at: Date.now(), kind: "user", seq: 4, text: "Cover it" };

test("a prompt's version arrows, Copy and Edit name themselves in a tooltip", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          edit: { seqs: new Map([["user-4", 3]]), send: async () => true },
          branches: { of: new Map([["user-4", { sessions: ["a", "b", "c"], index: 1 }]]), open: () => {} },
        }}
      >
        <UserBubble row={prompt} text="Cover it" />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(named(".cv-user__actions button")).toEqual([
    ["Previous version", "Previous version"],
    ["Next version", "Next version"],
    ["Copy", "Copy"],
    ["Edit", "Edit"],
  ]);
});

test("a prompt's Copy shows a check that reads Copied, then goes back to Copy", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <UserBubble row={prompt} text="Cover it" />
      </TurnActionsContext.Provider>,
    ),
  );
  const copy = host.querySelector<HTMLButtonElement>('.cv-user__actions button[aria-label="Copy"]')!;
  const idle = glyph(copy);
  await act(async () => copy.click());
  expect(copies).toEqual(["Cover it"]);
  expect([copy.getAttribute("aria-label"), copy.title]).toEqual(["Copied", "Copied"]);
  expect(glyph(copy)).not.toBe(idle);
  // It goes back after a moment, not for good.
  expect(timers.filter((timer) => timer.ms === COPIED_MS)).toHaveLength(1);
  await act(async () => copiedTimer().run());
  expect([copy.getAttribute("aria-label"), copy.title]).toEqual(["Copy", "Copy"]);
  expect(glyph(copy)).toBe(idle);
});

test("a turn's Copy names itself and turns into a check that goes back", async () => {
  const summary: AcpmuxRow = {
    id: "summary-3",
    version: 1,
    at: Date.now(),
    kind: "turnSummary",
    seq: 3,
    status: "completed",
    text: "Done.",
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <TurnFooter row={summary} />
      </TurnActionsContext.Provider>,
    ),
  );
  const copy = host.querySelector<HTMLButtonElement>('.cv-turn-actions button[aria-label="Copy"]')!;
  expect(copy.title).toBe("Copy");
  const idle = glyph(copy);
  await act(async () => copy.click());
  expect(copies).toEqual(["Done."]);
  expect([copy.getAttribute("aria-label"), copy.title]).toEqual(["Copied", "Copied"]);
  expect(glyph(copy)).not.toBe(idle);
  await act(async () => copiedTimer().run());
  expect([copy.getAttribute("aria-label"), glyph(copy)]).toEqual(["Copy", idle]);
});
