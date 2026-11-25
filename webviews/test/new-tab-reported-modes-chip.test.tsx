// l10n-allow-file: test fixtures.
// A new chat on a harness whose modes acpmux knows only from its harness row (`_acpmux/harnesses`
// `reported`: its startup probe, such as Antigravity's) and where acpmux sets no start mode (it has
// no full-access mode, start_mode.rs) draws a live Mode menu of those modes, named for the mode the
// harness starts in (`reported.startModeId`), never the inert "Mode" chip with no menu (Lucas
// 2026-11-25: "mode is still not working").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  const { setStartModeSource, resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

const AGY_MODES = [
  { id: "default", name: "Default", description: "Ask before edits and commands." },
  { id: "accept-edits", name: "Accept edits" },
  { id: "auto", name: "Auto" },
  { id: "plan", name: "Plan" },
];

/// Renders a New Tab composer's chips on the `antigravity` harness, whose catalog row is `entry`.
async function render(entry: Partial<Snapshot["catalog"][number]>) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  // acpmux sets no start mode on Antigravity (`modeId: null`).
  setStartModeSource(async () => undefined);
  const catalog = [
    {
      id: "antigravity",
      name: "Antigravity",
      family: "antigravity",
      models: [{ id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", efforts: ["low", "medium", "high"] }],
      reportsModes: true,
      ...entry,
    },
  ] as Snapshot["catalog"];
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
    summary: { sessionId: "", harness: "antigravity", turnCount: 0 },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "antigravity" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        holdsModePick
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
  await act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
}

const chip = () => host.querySelector<HTMLElement>(".acpmux-mode");
const label = () => (chip()?.querySelector(".acpmux-mode-text")?.textContent ?? "").trim();

test("the harness row's modes make a live Mode menu named for the harness's own start mode", async () => {
  await render({ reportedModes: AGY_MODES, ownStartMode: "default" });
  expect(chip()).not.toBeNull();
  expect(chip()!.classList.contains("acpmux-chip-pending")).toBe(false);
  expect(label()).toBe("Default");
});

test("with no own start mode known the menu is still live, and says Mode", async () => {
  await render({ reportedModes: AGY_MODES });
  expect(chip()).not.toBeNull();
  expect(chip()!.classList.contains("acpmux-chip-pending")).toBe(false);
  expect(label()).toBe("Mode");
});
