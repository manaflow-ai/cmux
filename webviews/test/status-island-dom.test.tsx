// l10n-allow-file: test fixture chat names, asks and errors, not shipped UI.
// The agent status island in a page (statusIsland/StatusIsland.tsx): a press on the pill or the
// card's collapse button swaps the island's content, and focus goes to the control in its place
// (the collapse button, the pill), never to the page's body and never to Allow. A failure the person
// folded that clears and comes back opens its card again, even under the same key. A command shows
// whole above Allow.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
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

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { StatusIsland } = await import("../src/agent-session/acpmux/statusIsland/StatusIsland");
const { islandState } = await import("../src/agent-session/acpmux/statusIsland/model");
const { needsYouItems } = await import("../src/agent-session/acpmux/needsYou/model");
type Session = import("../src/agent-session/acpmux/sessionList").AcpmuxSessionEntry;
type Ask = import("../src/agent-session/acpmux/needsYou/model").WatchedAsk;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const actions = { answer: async () => undefined, goTo: () => undefined, openSession: () => undefined };
const chat = (sessionId: string, fields: Partial<Session> = {}): Session => ({
  sessionId,
  title: sessionId,
  harness: "claude",
  ...fields,
});
const longCommand = `bun run lint && ${"echo step && ".repeat(30)}rm -rf ./dist`;
const ask: Ask = {
  sessionId: "Tab strip review",
  at: 2_000,
  permission: {
    permissionId: "p1",
    title: "Run the linter",
    command: longCommand,
    pending: true,
    options: [
      { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
      { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
    ],
  },
};
const render = async (sessions: Session[], asks: Ask[] = []) =>
  act(async () =>
    root.render(
      <StatusIsland state={islandState({ sessions, items: needsYouItems({ sessions, asks }) })} actions={actions} />,
    ),
  );
const q = (selector: string) => host.querySelector<HTMLElement>(selector);
const click = async (element: HTMLElement | null) =>
  act(async () => {
    element!.click();
  });

test("a press hands focus to the control in the pressed one's place, never to the body or Allow", async () => {
  await render([chat("Tab strip review")], [ask]);
  // The ask opened the card by itself: focus stays where it was.
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(dom.window.document.activeElement).toBe(dom.window.document.body);

  q(".acpmux-status-island__collapse")!.focus();
  await click(q(".acpmux-status-island__collapse"));
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();
  expect(dom.window.document.activeElement).toBe(q(".acpmux-status-island__pill"));

  await click(q(".acpmux-status-island__pill"));
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(dom.window.document.activeElement).toBe(q(".acpmux-status-island__collapse"));
  expect(dom.window.document.activeElement?.textContent).not.toBe("Allow");
});

test("the whole command shows above Allow", async () => {
  await render([chat("Tab strip review")], [ask]);
  const detail = q(".acpmux-status-island__detail[data-command]");
  expect(detail?.textContent).toBe(longCommand);
});

test("a folded failure that clears and comes back opens again, even under the same key", async () => {
  const failing = chat("Port the sheet", { indicator: "failed", laneError: "out of context", activityAt: 5 });
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  await click(q(".acpmux-status-island__collapse"));
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();

  // Still failed: it stays folded.
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();

  // It recovers and runs, then fails again (here with the same activityAt, the worst case).
  await render([chat("Port the sheet", { indicator: "working", activityAt: 5 })]);
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
});
