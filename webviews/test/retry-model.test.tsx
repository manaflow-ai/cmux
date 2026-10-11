// Retry with another model (cx-ncc.62, Claude parity): beside a turn's Retry, a menu lists the chat
// harness's models with the current one checked; picking one retries the prompt on that model. A
// harness with one model has no menu.
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

const summary = {
  id: "summary-3",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 3,
  status: "completed",
  text: "Done.",
  prompt: "Add retry to the uploader",
  retryRowId: "user-1",
};
const button = (label: string) =>
  [...dom.window.document.querySelectorAll("button")].find((element) => element.getAttribute("aria-label") === label);
const menuItem = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role^="menuitem"]')].find((item) =>
    item.textContent?.includes(label),
  );

test("Retry's model menu retries the prompt on the model picked there", async () => {
  const retried: unknown[][] = [];
  const actions = {
    retry: (rowId: string, prompt: string) => retried.push([rowId, prompt]),
    retryWith: {
      models: [
        { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
        { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
      ],
      current: "claude-opus-5-5",
      retry: (rowId: string, prompt: string, model: string) => retried.push([rowId, prompt, model]),
    },
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={summary} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => button("Retry with another model")!.click());
  expect(menuItem("Claude Opus 5.5")?.getAttribute("aria-checked")).toBe("true");
  await act(async () => menuItem("Claude Sonnet 5.5")!.click());
  expect(retried).toEqual([["user-1", "Add retry to the uploader", "claude-sonnet-5-5"]]);
});

test("a harness with one model offers Retry alone", async () => {
  const actions = {
    retry: () => {},
    retryWith: {
      models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }],
      current: "claude-opus-5-5",
      retry: () => {},
    },
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={summary} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(button("Retry")).toBeDefined();
  expect(button("Retry with another model")).toBeUndefined();
});
