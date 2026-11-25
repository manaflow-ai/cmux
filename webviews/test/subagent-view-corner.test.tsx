// l10n-allow-file: regression fixture text, not shipped UI.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
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
const { SubagentNavContext } = await import("../src/agent-session/acpmux/subagents/subagentGroupModel");
const { SubagentViewCorner } = await import("../src/agent-session/acpmux/subagents/SubagentViewCorner");
const { escapeClosesSubagent, useEscapeClosesSubagent } =
  await import("../src/agent-session/acpmux/subagents/subagentEscape");

afterAll(async () => {
  setPaneLanguage("en");
  await teardownDom(saved, { window: dom.window, scope });
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

test("a subagent's view draws no line about where it came from: its rows start as a chat's do", () => {
  const reply: AcpmuxRow = { id: "unit:reply", kind: "assistant", version: 1, at: 2, text: "All green." };
  const rows = childView("unit", [group], { unit: [reply] }, new Set())!;
  // Leo, 2026-11-22: "the metadata about provenance or whatever like subagent of something. we
  // shouldn't have those."
  expect(rows[0]?.id).toBe("unit:reply");
  expect(rows.every((row) => !row.id.endsWith(":of"))).toBe(true);
});

test("the in-place view's corner has a close that goes to the chat, and no provenance text", async () => {
  const root = createRoot(document.getElementById("root")!);
  const opened: (string | undefined)[] = [];
  const rows = childView("unit", [group], { unit: [] }, new Set())!;
  const unit = group.subagents![1]!;
  try {
    await act(async () =>
      root.render(
        <SubagentNavContext.Provider value={(id) => opened.push(id)}>
          <VirtualTranscript
            rows={rows}
            onToggleActivity={() => {}}
            expanded={new Set()}
            corner={<SubagentViewCorner agent={unit} close />}
          />
        </SubagentNavContext.Provider>,
      ),
    );
    const corner = document.querySelector<HTMLElement>(".acpmux-view-corner");
    expect(corner?.dataset.zone).toBe("top-end");
    // Over the rows, outside the scroller: it takes no row's room.
    expect(corner!.closest(".acpmux-scroll")).toBeNull();
    const close = corner!.querySelector<HTMLButtonElement>(".cv-subagent-corner__close");
    expect(close?.getAttribute("aria-label")).toBe("Close subagent");
    expect(document.body.textContent).not.toContain("Subagent of");
    expect(document.body.textContent).not.toContain("Lead");
    await act(async () => close!.click());
    expect(opened).toEqual([undefined]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a subagent's own pane draws no close in the corner: its tab closes it", async () => {
  const root = createRoot(document.getElementById("root")!);
  const rows = childView("unit", [group], { unit: [] }, new Set())!;
  try {
    await act(async () =>
      root.render(
        <SubagentNavContext.Provider value={() => {}}>
          <VirtualTranscript
            rows={rows}
            onToggleActivity={() => {}}
            expanded={new Set()}
            corner={<SubagentViewCorner agent={group.subagents![1]!} close={false} />}
          />
        </SubagentNavContext.Provider>,
      ),
    );
    expect(document.querySelector(".cv-subagent-corner__close")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat's own transcript draws no corner", async () => {
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={[group]} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    expect(document.querySelector(".acpmux-view-corner")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

// Lucas, 2026-11-06: in a split opened from the chat, going back to the chat closes the subagent tab and
// focuses the chat's own tab, instead of showing the chat a second time.
test("back to the opening chat asks the app, and says whether it went", async () => {
  const { backToOpeningChat } = await import("../src/agent-session/acpmux/subagents/subagentPanes");
  const asked: [string, Record<string, unknown>][] = [];
  const reply = (value: unknown) => async (method: string, params: Record<string, unknown>) => {
    asked.push([method, params]);
    return value;
  };
  expect(await backToOpeningChat(reply({ back: true }))).toBe(true);
  expect(asked).toEqual([["chat.subagentBack", {}]]);
  expect(await backToOpeningChat(reply({ back: false }))).toBe(false);
  // An older app refuses the method: the pane shows the chat in place.
  expect(
    await backToOpeningChat(async () => {
      throw new Error("unsupported");
    }),
  ).toBe(false);
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
