// Every harness in a new chat's model menu (paid-plan.md section 4).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(() => {
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// This Mac's acpmux has Claude Code (ready) and Codex, whose launcher check failed; the bundled
/// catalog also names OpenCode, Pi and Gemini CLI, which acpmux does not have here.
async function acpmuxCatalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const models = (id: string) =>
    BUNDLED_MODEL_CATALOG.harnesses
      .find((harness) => harness.id === id)!
      .models.map((model) => ({ id: model.id, name: model.name }));
  return [
    { id: "claude", name: "Claude Code", family: "claude", models: models("claude") },
    { id: "codex", name: "Codex", family: "codex", models: [], unavailable: "codex: not signed in" },
  ] as Snapshot["catalog"];
}

/// A New Tab (no session yet) on the composer's model menu.
async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const catalog = await acpmuxCatalog();
  const switched: string[] = [];
  let added = 0;
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, undefined, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        harnessesListed
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness) => switched.push(harness)}
        onAddAgent={() => (added += 1)}
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
  return { switched, added: () => added };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const menu = () => doc().querySelector<HTMLElement>(".acpmux-quick-menu");
const railTabs = () => [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab") ?? [])];
const labelOf = (item: Element) => item.querySelector(".acpmux-menu-label")?.textContent ?? item.textContent ?? "";
const itemsOf = (popup: HTMLElement) => [...popup.querySelectorAll<HTMLElement>('[role^="menuitem"]')];

async function open() {
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await settle();
}

async function showTab(name: string) {
  const tab = railTabs().find((candidate) => candidate.getAttribute("aria-label") === name);
  expect(
    tab,
    `${name} tab in ${railTabs()
      .map((each) => each.getAttribute("aria-label") ?? "")
      .join(", ")}`,
  ).toBeDefined();
  await act(async () => tab!.click());
  await settle();
}

// Lawrence 2026-10-23: "show all possible harnesses by default, and let user choose model". The
// rail lists every harness the catalog or acpmux names, set up here or not; one that cannot start
// is marked (Not installed, Unavailable) with its way to set it up, never hidden, and never starts
// a chat that fails on its first turn.
test("a new chat's model menu lists every harness, the ones not set up marked with Install", async () => {
  const { switched, added } = await mount();
  await open();
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label"));
  for (const name of ["Claude Code", "Codex", "OpenCode", "Pi", "Gemini CLI"]) expect(tabs).toContain(name);
  await showTab("Gemini CLI");
  const labels = itemsOf(menu()!).map(labelOf);
  expect(labels).toContain("Not installed");
  const install = itemsOf(menu()!).find((item) => labelOf(item) === "Install…");
  expect(install, labels.join(", ")).toBeDefined();
  await act(async () => install!.click());
  await settle();
  expect(added()).toBe(1);
  expect(switched).toEqual([]);
});

test("a harness whose launcher check failed stays listed, marked Unavailable", async () => {
  const { switched } = await mount();
  await open();
  await showTab("Codex");
  const labels = itemsOf(menu()!).map(labelOf);
  expect(labels).toContain("Unavailable");
  expect(labels).toContain("Setup guide");
  expect(switched).toEqual([]);
});

test("the full picker lists the harnesses that are not set up too", async () => {
  await mount();
  // Cmd-Ctrl-M opens the full picker.
  await act(async () =>
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true })),
  );
  await settle();
  const rail = [...doc().querySelectorAll<HTMLElement>(".acpmux-mp-harness")];
  const titles = rail.map((tab) => tab.getAttribute("title") ?? "");
  expect(
    titles.some((title) => title.startsWith("Gemini CLI")),
    titles.join(", "),
  ).toBe(true);
  expect(
    titles.some((title) => title.startsWith("Codex")),
    titles.join(", "),
  ).toBe(true);
  const gemini = rail.find((tab) => (tab.getAttribute("title") ?? "").startsWith("Gemini CLI"))!;
  await act(async () => gemini.click());
  await settle();
  expect(doc().querySelector(".acpmux-mp-models")?.textContent).toContain("Not installed");
});
