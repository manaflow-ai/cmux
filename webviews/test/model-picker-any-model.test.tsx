// The model menu's search over every harness the catalog knows (Lawrence 2026-11-07: "we should make
// it possible to search for any model in cmux model picker"), narrowed to the harnesses this Mac has
// (Lucas 2026-11-25): one that is not installed lists no models, in a tab or a search, so no pick
// installs it; its tab offers Install. The real composer, catalog and menu, in JSDOM, over a fake
// app host.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  // The DOM constructors the menus and App's registered elements read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  // The page-wide setup a pick started goes with the test.
  (await import("../src/agent-session/acpmux/harnessSetup").catch(() => undefined))?.resetHarnessSetupForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Call = { method: string; params: Record<string, unknown> };

/// This Mac's acpmux: Claude Code and Codex only. Gemini CLI and OpenCode are not installed.
async function installedCatalog(extra: Snapshot["catalog"] = []): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return [
    ...BUNDLED_MODEL_CATALOG.harnesses
      .filter((harness) => harness.id === "claude" || harness.id === "codex")
      .map((harness) => ({
        id: harness.id,
        name: harness.name,
        family: harness.families[0],
        models: harness.models.map((model) => ({ id: model.id, name: model.name })),
      })),
    ...extra,
  ] as Snapshot["catalog"];
}

function newChat(catalog: Snapshot["catalog"]): Snapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: { sessionId: "s1", harness: "claude", model: "claude-opus-5-5", turnCount: 0 },
  } as Snapshot;
}

/// A New Tab's composer on the fake host `answer`. `relist` swaps acpmux's harness list (its
/// rescan after an install).
async function mount(answer: (call: Call, relist: (next: Snapshot["catalog"]) => void) => unknown) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { setNativeHost } = await import("../src/agent-session/acpmux/native");
  const { useState } = await import("react");
  const calls: Call[] = [];
  const switched: { harness: string; model?: string }[] = [];
  let relist: (next: Snapshot["catalog"]) => void = () => undefined;
  setNativeHost(async (method, params) => {
    calls.push({ method, params });
    // The bundled catalog stands in for the host's (an app without `models.catalog`).
    if (method === "models.catalog") return {};
    return answer({ method, params }, (next) => act(() => relist(next)));
  });
  const first = await installedCatalog();
  function Host() {
    const [catalog, setCatalog] = useState(first);
    relist = setCatalog;
    const snapshot = newChat(catalog);
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        catalogRefresh={{ refresh: picker.refresh }}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness, model) => switched.push({ harness, ...(model ? { model } : {}) })}
        harnessesListed
        startsChat
        setupPollMs={5}
        showPlan={false}
      />
    );
  }
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    ),
  );
  return { calls, switched };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const menu = () => doc().querySelector<HTMLElement>(".acpmux-cols");
const nameOf = (row: Element) => row.querySelector(".acpmux-cols-name")?.textContent ?? "";
const rows = () => [...(menu()?.querySelectorAll<HTMLElement>('[role="listbox"] [role="option"]') ?? [])];
const rowNames = () => rows().map(nameOf);
/// The search's headings: one per harness family, in the order the menu lists them.
const groupNames = () =>
  [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-cols-group") ?? [])].map((group) => group.textContent ?? "");
const chip = () => host.querySelector<HTMLElement>('[data-menu="Model"]')!;

async function click(element: HTMLElement) {
  await act(async () => element.click());
  await settle();
}
const open = () => click(chip());
const field = () => menu()!.querySelector<HTMLInputElement>(".acpmux-cols-search input[type=search]")!;
async function search(text: string) {
  await act(async () => {
    const input = field();
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await settle();
}

// Lucas 2026-11-25: "we should not display their models if they are not installed" (search too). A
// harness this Mac does not have lists no models, so no pick installs it: its tab says "Gemini CLI
// not installed" with an Install row, and the search finds only the harnesses set up here.
test("the search lists no model of a harness this Mac does not have", async () => {
  await mount(() => ({}));
  await open();
  await search("gemini 3.8 flash");
  expect(groupNames().some((name) => name.startsWith("Gemini CLI"))).toBe(false);
  expect(rowNames()).not.toContain("3.8 Flash");
  // OpenCode is not installed either: the feed's OpenCode Zen and Go models stay out.
  await search("deepseek v4.1 flash");
  expect(rowNames().some((name) => name.startsWith("DeepSeek V4.1 Flash"))).toBe(false);
  // A model of a harness set up here is still found.
  await search("opus");
  expect(rowNames().length).toBeGreaterThan(0);
});
