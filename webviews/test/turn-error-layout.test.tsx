// Agent chat dogfood (2026-10-12): a failed turn drew its error inside the turn's footer row,
// squeezed between "Worked for 42s" with Retry on the left and the time on the right, so a rate
// limit read as a narrow column. The failure reads as the turn's answer does: its own block, above
// the footer row that holds Worked for, Retry and the time (Codex, Claude desktop).
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
  durationMs: 42_000,
  error: "API Error: 529 overloaded_error",
  prompt: "Add retries with backoff to the fetch helper",
  retryRowId: "user-1",
};

test("a failed turn's error sits above its footer row, not inside it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed} />
      </TurnActionsContext.Provider>,
    ),
  );
  const note = host.querySelector(".cv-turn-note")!;
  const footer = host.querySelector(".cv-turn-actions")!;
  expect(note).not.toBeNull();
  expect(footer.contains(note)).toBe(false);
  expect(note.compareDocumentPosition(footer) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  // The footer row keeps the turn's own line: its time and Retry.
  expect(footer.querySelector(".cv-turn-time")).not.toBeNull();
  expect(footer.querySelector('[aria-label="Retry"]')).not.toBeNull();
});
