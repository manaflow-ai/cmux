// l10n-allow-file: test fixtures.
// A New Tab whose snapshot names no harness yet (newTabStart found no last pick or default it may
// take) still names one on its chips: the picker's face. Its Mode chip read "Bypass permissions"
// but was the inert placeholder, so no click opened a menu (probe local-composer-matrix-nightly,
// gui.lc_mode.mode_not_picked, 21 runs: "no mode menu opened and the chip still reads Bypass
// permissions"). The chip is a live menu there, and its pick names the face harness, the one the
// page's deferred chat starts on (ComposerChips `start`).
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
];

/// A New Tab composer's chips whose snapshot names no harness yet (`summary` has none): the chips
/// name the picker's face harness, `antigravity`, the only one listed.
async function render(props: { startsChat?: boolean; holdsModePick?: boolean }, picks: [string, string?][]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(async () => undefined);
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [
      {
        id: "antigravity",
        name: "Antigravity",
        family: "antigravity",
        models: [{ id: "gemini-3.8-flash", name: "Gemini 3.8 Flash" }],
        reportsModes: true,
        reportedModes: AGY_MODES,
        ownStartMode: "default",
      },
    ],
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, {});
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={(modeId, harness) => void picks.push([modeId, harness])}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        {...props}
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
const item = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].find((row) =>
    row.textContent?.includes(name),
  );

test("a New Tab naming its harness only on its chips draws a live Mode menu, and a pick names that harness", async () => {
  const picks: [string, string?][] = [];
  await render({ startsChat: true }, picks);
  expect(chip()).not.toBeNull();
  expect(chip()!.classList.contains("acpmux-chip-pending")).toBe(false);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await act(async () => item("Accept edits")!.click());
  expect(picks).toEqual([["accept-edits", "antigravity"]]);
});

test("a started chat's chips with no session modes keep the inert chip (no pick to hold)", async () => {
  await render({}, []);
  expect(chip()?.classList.contains("acpmux-chip-pending") ?? true).toBe(true);
});
