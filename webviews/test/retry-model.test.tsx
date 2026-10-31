// Retry with another model (cx-ncc.62, Claude parity): beside a prompt's Retry, a menu lists the chat
// harness's models with the current one checked; picking one retries the prompt on that model. A
// harness with one model has no menu.
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
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
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

const prompt: AcpmuxRow = {
  id: "user-1",
  version: 1,
  at: Date.now(),
  kind: "user",
  seq: 1,
  text: "Add retry to the uploader",
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
        <UserBubble row={prompt} text={prompt.text!} />
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
        <UserBubble row={prompt} text={prompt.text!} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(button("Retry")).toBeDefined();
  expect(button("Retry with another model")).toBeUndefined();
});

// Lawrence and Leo 2026-10-20: the menu showed Claude Code's whole list as one raw column, aliases
// and old releases mixed, Opus 5.5, Sonnet 5.5 and Haiku 5.5 twice. It lists the harness's curated
// top models first, as the composer's model menu does, every other model under More models, and a
// model the harness offers twice as one row; the current one stays checked.
/** A row's name, without its check or its detail ("1M context"). */
const rowName = (item: Element) => item.querySelector(".acpmux-menu-label")?.textContent?.trim();
const shownRows = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitemradio"]')].map(rowName);

test("Retry's model menu lists the top models, the rest under More models, one row per model", async () => {
  const retried: unknown[][] = [];
  const actions = {
    retry: () => {},
    retryWith: {
      models: [
        { id: "opus", name: "Opus 5.5", release: "claude-opus-5-5" },
        { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
        { id: "sonnet", name: "Sonnet 5.5", release: "claude-sonnet-5-5" },
        { id: "opusplan", name: "Opus plan · Sonnet execute" },
        { id: "claude-fable-5-1", name: "Fable 5.1" },
        { id: "claude-opus-5-5", name: "Opus 5.5" },
        { id: "claude-opus-4-8", name: "Opus 4.8" },
        { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
        { id: "claude-haiku-5-5", name: "Haiku 5.5" },
      ],
      current: "claude-opus-5-5",
      harness: "Claude Code",
      top: ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
      retry: (rowId: string, prompt: string, model: string) => retried.push([rowId, prompt, model]),
    },
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={prompt} text={prompt.text!} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => button("Retry with another model")!.click());
  const menu = dom.window.document.querySelector('[role="menu"]')!;
  expect(menu.classList.contains("acpmux-quick-menu"), "the composer model menu's look").toBe(true);
  expect(shownRows()).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]);
  const detail = [...menu.querySelectorAll(".acpmux-quick-value")].map((element) => element.textContent);
  expect(detail).toEqual([]);
  const checked = [...dom.window.document.querySelectorAll('[role="menuitemradio"][aria-checked="true"]')];
  expect(checked.map(rowName)).toEqual(["Opus 5.5"]);
  const more = [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.includes("More models"),
  );
  expect(more, "older models fold under More models").toBeDefined();
  await act(async () => menuItem("Fable 5.1")!.click());
  expect(retried).toEqual([["user-1", "Add retry to the uploader", "claude-fable-5-1"]]);
});
