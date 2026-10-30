// Return on a New Tab page starts the chat on the model its chip names (dogfood run 5). With
// nothing picked yet the chip names the agent's catalog default ("Claude Sonnet 5"), but the
// page asked `chat.new` with no model, so the chat started on whatever the agent itself
// defaults to (Opus 5.5 on that account): the chip promised one model and the chat ran another.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
] as const;
const added: string[] = [];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
    // The composer's footer row fits its chips to its width (composerRowFit.ts) on every New Tab.
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

test("Return on a New Tab asks the agent on the model its chip names", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  const actions = newTabScreenActions({
    callNative: async (method, params) => void calls.push({ method, params }),
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen
            snapshot={noChat()}
            lastAgent="claude"
            cwd="/Users/you/src/app"
            chips={NewTabComposerChips}
            {...actions}
          />
        </QueryClientProvider>,
      ),
    );
    const chip = host.querySelector(".acpmux-model-name")?.textContent ?? "";
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "fix the flaky upload test");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    const asked = calls.find((call) => call.method === "chat.new")?.params;
    const models = BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === "claude")!.models;
    // The model the chip names, by its catalog name, with or without the brand ("Opus 5.5" and
    // "Claude Opus 5.5" name the same model).
    const plain = (name: string) => name.replace(/^Claude /, "");
    const shown = models.find((model) => plain(model.name) === plain(chip));
    expect(shown).toBeDefined();
    expect({ chip, harness: asked?.harness, model: asked?.model }).toEqual({
      chip,
      harness: "claude",
      model: shown!.id,
    });
  } finally {
    await act(async () => root.unmount());
  }
});

test("New Tab preflights its selected harness and keeps a refused draft", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
  const queries: unknown[] = [];
  const asks: unknown[] = [];
  const readSessionAuth = async (query: unknown) => {
    queries.push(query);
    return { state: "expired", source: "authCheck", evidenceAt: 1, harness: "codex", host: null };
  };
  const root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <SignInContext.Provider value={{ signedOut: {}, logIn: noop, readSessionAuth }}>
            <NewTabScreen
              snapshot={noChat()}
              lastAgent="codex"
              cwd="/Users/you/src/app"
              onAsk={(...args) => {
                asks.push(args);
              }}
              onOpen={noop}
              onSearch={noop}
              onShell={noop}
              onJump={noop}
              onOpenSession={noop}
              onShowAll={noop}
            />
          </SignInContext.Provider>
        </QueryClientProvider>,
      ),
    );
    expect(queries).toEqual([{ target: { harness: "codex" } }]);
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setter.call(field, "keep this draft");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () =>
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
    expect(asks).toEqual([]);
    expect(field.value).toBe("keep this draft");
    expect(host.querySelector("[role=alert]")?.textContent).toContain("expired");
  } finally {
    await act(async () => root.unmount());
  }
});
