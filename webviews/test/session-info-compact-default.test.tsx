// l10n-allow-file: test fixture names, not shipped UI.
// Session Info's default view is short (Leo, 2026-11-03: "i feel like it's a bit too much stuff by
// default there's a bunch of things there that can be a bit more hidden under 'show more' or
// whatnot"): his four (the machine, Context, subagents and background tasks, Sources) show, and the
// less-used sections (Usage, Changes, Outputs, Connectors) wait behind one Show more that names them.
// - No section is dropped: Show more draws every one, in the panel's order, and Show less hides them.
// - The choice stays: a new panel reads it back, and a chat saved before Show more starts compact.
// - A person's own choices win: a fold saved shut stays shut under Show more, and a less-used section
//   dragged above one of the four stays in view.
// - A reveal (a running line's count, the header's chip) of a held section opens Show more.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
const { ORDER_KEY, resetSectionOrderForTests, tuckedSections, DEFAULT_ORDER } =
  await import("../src/agent-session/acpmux/session-info/sectionOrder");
const gallery = (await import("../src/agent-session/acpmux/session-info/SessionInfo.gallery")).default;
type SessionInfoProps = import("react").ComponentProps<typeof SessionInfo>;

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

// The gallery's full chat, every section present, as a pane draws it: Show more from the pane's state.
const full = { ...(gallery.variants.full!.props as SessionInfoProps), sections: undefined, more: undefined };
const FOUR = ["environment", "context", "subagents", "tasks", "sources"];
const EVERY = ["environment", "context", "usage", "subagents", "tasks", "sources", "changes", "outputs", "connectors"];

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

test("opening Session Info shows machine details and collapsed section summaries", async () => {
  const { container, root } = await mount();
  expect(container.querySelector('[data-section="environment"] [data-machine]')).not.toBeNull();
  const triggers = [...container.querySelectorAll(".ui-disclosure-trigger")];
  expect(triggers.length).toBeGreaterThan(0);
  expect(triggers.every((trigger) => trigger.getAttribute("aria-expanded") === "false")).toBe(true);
  await act(async () => root.unmount());
});

test("the default view draws Leo's four and one Show more naming the rest", async () => {
  const { container, root } = await mount();
  expect(drawn(container)).toEqual(FOUR);
  const button = more(container)!;
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(button.textContent).toBe("Show more· Usage · Changes · Outputs · Connectors");
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

test("a chat with nothing less-used draws no Show more", async () => {
  const { container, root } = await mount({
    ...full,
    made: { ...full.made!, pullRequests: [], outputs: [] },
    links: [],
    artifacts: 0,
    summary: { ...full.summary!, mcpServers: [], usageStats: undefined },
    allSessions: [],
  });
  expect(drawn(container).some((id) => ["usage", "changes", "outputs", "connectors"].includes(id))).toBe(false);
  expect(more(container)).toBeNull();
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

test("a less-used section dragged above one of the four stays in view", async () => {
  dom.window.localStorage.setItem(
    ORDER_KEY,
    JSON.stringify(["changes", ...DEFAULT_ORDER.filter((id) => id !== "changes")]),
  );
  resetSectionOrderForTests();
  const { container, root } = await mount();
  expect(drawn(container)).toEqual(["changes", ...FOUR]);
  expect(more(container)!.textContent).toBe("Show more· Usage · Outputs · Connectors");
  await act(async () => root.unmount());
});

test("tuckedSections: the default order holds back every less-used section; a drag above wins", () => {
  expect(tuckedSections(DEFAULT_ORDER)).toEqual(["usage", "changes", "outputs", "connectors"]);
  // Usage moved above Context: placed by the person.
  const usageFirst = [
    "environment",
    "usage",
    "context",
    "subagents",
    "tasks",
    "sources",
    "changes",
    "outputs",
    "connectors",
  ] as const;
  expect(tuckedSections(usageFirst)).toEqual(["changes", "outputs", "connectors"]);
  // Outputs moved between the four but below none it follows by default... above Sources: placed.
  const outputsUp = [
    "environment",
    "context",
    "usage",
    "outputs",
    "subagents",
    "tasks",
    "sources",
    "changes",
    "connectors",
  ] as const;
  expect(tuckedSections(outputsUp)).toEqual(["usage", "changes", "connectors"]);
});

test("revealing a held section opens Show more and draws it", async () => {
  const { container, root } = await mount({
    ...full,
    revealed: { section: "outputs", at: 1 },
    onRevealed: () => undefined,
  });
  expect(drawn(container)).toContain("outputs");
  expect(sessionInfoState().more).toBe(true);
  await act(async () => root.unmount());
});
