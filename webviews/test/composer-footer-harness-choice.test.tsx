// l10n-allow-file: test fixtures.
// The composer footer contains only mode/model controls. Harness choice lives in the model picker's
// left rail, so the quiet row never repeats the harness name or mark.
//   - only Codex installed and none picked: the bundled catalog can list Claude first, but the model
//     button draws Codex, so the row names Codex and the chips are Codex's;
//   - before acpmux lists its harnesses, the access chip holds its place from the first frame
//     (#24517) and the row names no harness yet;
//   - acpmux lists none: no harness item and no mode chip, only Add harness.
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
  const { resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// The quiet row for a new chat that names no harness, once acpmux listed `installed` (undefined:
/// it has not answered yet), over the bundled model catalog.
async function render(installed: string[] | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { ComposerFoot } = await import("../src/agent-session/acpmux/ComposerFoot");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const catalog = BUNDLED_MODEL_CATALOG.harnesses
    .filter((entry) => installed?.includes(entry.id))
    .map((entry) => ({
      id: entry.id,
      name: entry.name,
      family: entry.families[0],
      models: entry.models.map((model) => ({ id: model.id, name: model.name })),
    })) as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    origin: "local",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: { sessionId: "", turnCount: 0 },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, {});
    return (
      <ComposerFoot>
        <ComposerPickers
          snapshot={snapshot}
          pickerCatalog={picker.catalog}
          harnessesListed={installed !== undefined}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={() => undefined}
          onHarness={() => undefined}
          onAddAgent={() => undefined}
          showPlan={false}
        />
      </ComposerFoot>
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
}

const foot = () => host.querySelector<HTMLElement>(".acpmux-composer-foot")!;
const mark = (selector: string) => foot().querySelector<SVGElement>(`${selector} svg.agent-mark`)?.dataset.agent;

test("with only Codex installed and none picked, the quiet row does not repeat the harness", async () => {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  // The case: the bundled catalog lists another harness before Codex.
  expect(BUNDLED_MODEL_CATALOG.harnesses[0]?.id).not.toBe("codex");
  await render(["codex"]);
  expect(foot().querySelector(".acpmux-foot-harness")).toBeNull();
  expect(mark(".acpmux-model")).toBe("openai");
  expect(foot().querySelector(".acpmux-add-harness")).toBeNull();
});

test("before acpmux lists its harnesses the mode chip holds its place from the first frame; no harness is named", async () => {
  await render(undefined);
  expect(foot().querySelector(".acpmux-foot-harness")).toBeNull();
  const mode = foot().querySelector<HTMLElement>(".acpmux-mode .acpmux-picker-button");
  expect(mode).not.toBeNull();
  expect(mode!.textContent?.trim()).toBeTruthy();
});

test("with no harness installed the row names no harness and draws no mode chip, only Add harness", async () => {
  await render([]);
  expect(foot().querySelector(".acpmux-foot-harness")).toBeNull();
  expect(foot().querySelector(".acpmux-mode, .acpmux-access")).toBeNull();
  expect(foot().textContent?.trim()).toBe("Add harness");
});
