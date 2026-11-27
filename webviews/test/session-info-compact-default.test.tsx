// l10n-allow-file: test fixture names, not shipped UI.
// Session Info's default view is short (Leo, 2026-11-03: "i feel like it's a bit too much stuff by
// default there's a bunch of things there that can be a bit more hidden under 'show more' or
// whatnot"): the sections above the Show more line show (the machine, Context, subagents and
// background tasks, Sources, Outputs), and the ones under it (Changes, Usage, Connectors) wait behind it.
// - The line is an item of the order (sectionOrder.ts MORE_LINE): its words stay in place, and open it
//   reads Show less over the sections it holds.
// - No section is dropped: Show more draws every one, in the panel's order, and Show less hides them.
// - The choice stays: a new panel reads it back.
// - A person's own choices win: a fold saved shut stays shut under Show more, and a section dragged
//   above the line stays in view.
// - A reveal (a running line's count, the header's chip) of a held section opens Show more.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
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
  localStorage: dom.window.localStorage,
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|Keyboard|Mouse|Focus|Event|Storage)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SessionInfo } = await import("../src/agent-session/acpmux/session-info/SessionInfo");
const { resetSessionInfoState, sessionInfoState, setSessionInfoSection } =
  await import("../src/agent-session/acpmux/session-info/sessionInfoState");
const { MORE_LINE, ORDER_KEY, resetSectionOrderForTests, tuckedSections, DEFAULT_ORDER } =
  await import("../src/agent-session/acpmux/session-info/sectionOrder");
const gallery = (await import("../src/agent-session/acpmux/session-info/SessionInfo.gallery")).default;
type SessionInfoProps = import("react").ComponentProps<typeof SessionInfo>;

afterAll(async () => {
  setPaneLanguage("en");
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

// The gallery's full chat, every section present, as a pane draws it: Show more from the pane's state.
const full = { ...(gallery.variants.full!.props as SessionInfoProps), more: undefined };
const FOUR = ["environment", "context", "subagents", "tasks", "sources", "outputs", "more"];
const EVERY = [...FOUR, "changes", "usage", "connectors"];

beforeEach(() => {
  dom.window.localStorage.clear();
  resetSectionOrderForTests();
  resetSessionInfoState();
});

async function mount(props: SessionInfoProps = full) {
  const container = dom.window.document.createElement("main");
  dom.window.document.body.replaceChildren(container);
  const root = createRoot(container);
  await act(async () => root.render(createElement(SessionInfo, props)));
  return { container, root };
}
const drawn = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-session-info-sections > [data-slot]")].map(
    (slot) => slot.dataset.slot!,
  );
const more = (container: HTMLElement) => container.querySelector<HTMLButtonElement>(".acpmux-session-info-more");

test("the default view draws what is above the line, then the line's Show more", async () => {
  const { container, root } = await mount();
  expect(drawn(container)).toEqual(FOUR);
  const button = more(container)!;
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(button.textContent).toBe("Show more");
  await act(async () => button.click());
  expect(drawn(container)).toEqual(EVERY);
  expect(more(container)!.getAttribute("aria-expanded")).toBe("true");
  expect(more(container)!.textContent).toBe("Show less");
  await act(async () => more(container)!.click());
  expect(drawn(container)).toEqual(FOUR);
  await act(async () => root.unmount());
});

test("Show more stays open for a new panel", async () => {
  const first = await mount();
  await act(async () => more(first.container)!.click());
  expect(sessionInfoState().more).toBe(true);
  await act(async () => first.root.unmount());
  const second = await mount();
  expect(drawn(second.container)).toEqual(EVERY);
  await act(async () => second.root.unmount());
});

test("a chat with nothing less-used still holds Usage and Connectors under Show more, each one plain line", async () => {
  const { container, root } = await mount({
    ...full,
    made: { ...full.made!, pullRequests: [], outputs: [] },
    artifacts: 0,
    summary: { ...full.summary!, mcpServers: [], usageStats: undefined },
    allSessions: [],
    imessage: false,
  });
  expect(drawn(container)).not.toContain("changes");
  await act(async () => more(container)!.click());
  expect(drawn(container).slice(-3)).toEqual([MORE_LINE, "usage", "connectors"]);
  for (const id of ["usage", "connectors"]) {
    const section = container.querySelector<HTMLElement>(`section[data-section="${id}"]`)!;
    expect(section.querySelector(".ui-disclosure-trigger")).toBeNull();
    expect(section.querySelector(".acpmux-session-info-section__meta")?.textContent).toBe("None");
  }
  await act(async () => root.unmount());
});

test("a fold saved shut stays shut under Show more", async () => {
  setSessionInfoSection("changes", false);
  const { container, root } = await mount();
  await act(async () => more(container)!.click());
  const trigger = container.querySelector('[data-slot="changes"] .ui-disclosure-trigger');
  expect(trigger?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => root.unmount());
});

test("a less-used section dragged above the line stays in view", async () => {
  dom.window.localStorage.setItem(
    ORDER_KEY,
    JSON.stringify([
      "environment",
      "changes",
      ...DEFAULT_ORDER.filter((id) => id !== "changes" && id !== "environment"),
    ]),
  );
  resetSectionOrderForTests();
  const { container, root } = await mount();
  // Right under the pinned Environment (sectionOrder.ts PINNED_TOP).
  expect(drawn(container)).toEqual(["environment", "changes", ...FOUR.slice(1)]);
  await act(async () => root.unmount());
});

test("tuckedSections: what the order puts under the line", () => {
  expect(tuckedSections(DEFAULT_ORDER)).toEqual(["changes", "usage", "connectors"]);
  // Usage moved above the line: placed by the person; Sources moved under it: tucked.
  const moved = [
    "environment",
    "usage",
    "context",
    "subagents",
    "tasks",
    "outputs",
    MORE_LINE,
    "sources",
    "changes",
    "connectors",
  ] as const;
  expect(tuckedSections(moved)).toEqual(["sources", "changes", "connectors"]);
});

test("revealing a held section opens Show more and draws it", async () => {
  const { container, root } = await mount({
    ...full,
    revealed: { section: "usage", at: 1 },
    onRevealed: () => undefined,
  });
  expect(drawn(container)).toContain("usage");
  expect(sessionInfoState().more).toBe(true);
  await act(async () => root.unmount());
});
