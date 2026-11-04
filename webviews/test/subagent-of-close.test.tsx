// l10n-allow-file: regression fixture text, not shipped UI.
import { afterAll, expect, test } from "bun:test";
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
  customElements: dom.window.customElements,
  Node: dom.window.Node,
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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SUBAGENTS } = await import("../src/agent-session/acpmux/subagents/subagentFold");
const { childView } = await import("../src/agent-session/acpmux/subagents/subagentRows");
const { SubagentNavContext } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { escapeClosesSubagent, useEscapeClosesSubagent } =
  await import("../src/agent-session/acpmux/subagents/subagentEscape");

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// Leo, 2026-11-03: "this opened subagent has no close button".
const group: AcpmuxRow = {
  id: "group",
  kind: SUBAGENTS,
  version: 1,
  at: 1,
  subagents: [
    { id: "lead", parent: null, name: "Lead", state: "running", startedAt: 1 },
    { id: "unit", parent: "lead", name: "Unit tests", state: "completed", startedAt: 1 },
  ],
};

test("the Subagent of pill has a close button that closes to the chat, and its text goes to the parent", async () => {
  const root = createRoot(document.getElementById("root")!);
  const opened: (string | undefined)[] = [];
  const rows = childView("unit", [group], { unit: [] }, new Set(), "Release review")!;
  try {
    await act(async () =>
      root.render(
        <SubagentNavContext.Provider value={(id) => opened.push(id)}>
          <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />
        </SubagentNavContext.Provider>,
      ),
    );
    const close = document.querySelector<HTMLButtonElement>(".cv-subagent-of__close");
    expect(close).not.toBeNull();
    expect(close!.getAttribute("aria-label")).toBe("Close subagent");
    // The × is its own control beside the pill's text, not inside the back button.
    expect(close!.closest(".cv-subagent-of__pill")).toBeNull();
    await act(async () => close!.click());
    expect(opened).toEqual([undefined]);
    await act(async () => document.querySelector<HTMLElement>(".cv-subagent-of__pill")!.click());
    expect(opened).toEqual([undefined, "lead"]);
  } finally {
    await act(async () => root.unmount());
  }
});

const escape = (init: KeyboardEventInit = {}) =>
  new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true, ...init });

test("Escape closes the subagent's view unless a text field, a modifier or an open menu has it", () => {
  const doc = dom.window.document;
  expect(escapeClosesSubagent(escape() as unknown as KeyboardEvent, doc)).toBe(true);
  expect(escapeClosesSubagent(escape({ metaKey: true }) as unknown as KeyboardEvent, doc)).toBe(false);
  const taken = escape();
  taken.preventDefault();
  expect(escapeClosesSubagent(taken as unknown as KeyboardEvent, doc)).toBe(false);
  const field = doc.createElement("textarea");
  doc.body.append(field);
  const typed = escape();
  field.dispatchEvent(typed);
  expect(escapeClosesSubagent(typed as unknown as KeyboardEvent, doc)).toBe(false);
  field.remove();
  const menu = doc.createElement("div");
  menu.setAttribute("role", "menu");
  doc.body.append(menu);
  expect(escapeClosesSubagent(escape() as unknown as KeyboardEvent, doc)).toBe(false);
  menu.remove();
  // Session Info takes Escape while the keyboard is in it or on its toggle.
  const aside = doc.createElement("aside");
  aside.className = "acpmux-session-info";
  const inside = doc.createElement("button");
  aside.append(inside);
  doc.body.append(aside);
  inside.focus();
  expect(escapeClosesSubagent(escape() as unknown as KeyboardEvent, doc)).toBe(false);
  inside.blur();
  expect(escapeClosesSubagent(escape() as unknown as KeyboardEvent, doc)).toBe(true);
  aside.remove();
});

test("the hook closes on an unclaimed Escape and claims it, and does nothing while off", async () => {
  const root = createRoot(document.getElementById("root")!);
  let closed = 0;
  function Probe({ on }: { on: boolean }) {
    useEscapeClosesSubagent(on, () => closed++);
    return null;
  }
  try {
    await act(async () => root.render(<Probe on={false} />));
    document.body.dispatchEvent(escape());
    await Promise.resolve();
    expect(closed).toBe(0);
    await act(async () => root.render(<Probe on />));
    const event = escape();
    document.body.dispatchEvent(event);
    await Promise.resolve();
    expect(closed).toBe(1);
    expect(event.defaultPrevented).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});
