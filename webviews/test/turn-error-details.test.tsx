// Agent chat dogfood (2026-10-12): a failed turn's Details drew the browser's own "▶" disclosure
// triangle, unlike every other fold in the chat ("Worked for ›", "Thought ⌄"), which use the chat's
// chevron and turn it a quarter when open.
import { afterAll, expect, test } from "bun:test";
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
  // The menu places itself with floating-ui, which reads the page's styles.
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
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");

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

const failed = {
  id: "summary-2",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 2,
  status: "failed",
  error: "API Error: 529 overloaded_error",
  prompt: "Add retries with backoff to the fetch helper",
};

test("a failed turn's Details uses the chat's chevron, turned when open", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <TurnFooter row={failed} />
      </TurnActionsContext.Provider>,
    ),
  );
  const details = host.querySelector(".cv-turn-note details") as HTMLDetailsElement;
  const summary = details.querySelector("summary")!;
  expect(summary.textContent).toBe("Details");
  const chevron = () => summary.querySelector("svg.cv-rotor");
  expect(chevron()).not.toBeNull();
  expect(chevron()!.classList.contains("is-open")).toBe(false);
  await act(async () => {
    details.open = true;
    details.dispatchEvent(new dom.window.Event("toggle"));
  });
  expect(chevron()!.classList.contains("is-open")).toBe(true);
});
