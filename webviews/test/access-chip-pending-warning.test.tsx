// l10n-allow-file: test fixtures.
// A new chat that starts in a mode that skips approvals (bypassPermissions, agent-full-access: the
// access mode the person picked last, cx-uq9xi) draws its remembered access chip in the warning
// treatment on the first frame, as the live chip does, never neutral first. A remembered entry from
// before the mode id was kept draws its label without it.
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;

function reported(sessionId: string, currentModeId: string): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "default",
    turnCount: 0,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
    },
  };
}

/// Renders the composer's chips for `summary` (undefined: a new chat whose session has not reported).
async function render(summary: Summary) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
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
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: summary ?? { sessionId: "", harness: "claude", turnCount: 0 },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
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
}

/// The access chip: its label and whether it has the warning treatment.
const access = () => {
  const chip = host.querySelector<HTMLElement>(".acpmux-mode");
  return (
    chip && {
      label: (chip.querySelector(".acpmux-mode-text")?.textContent ?? "").trim(),
      warning: chip.classList.contains("acpmux-unrestricted"),
    }
  );
};

async function fresh() {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await render(undefined);
}

test("a new chat after one that skipped approvals draws its access chip in the warning treatment at once", async () => {
  await render(reported("earlier", "bypassPermissions"));
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });

  // A new chat, before its session reports: the same chip, warning included.
  await fresh();
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).not.toBeNull();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });

  // Its session reports the same mode: nothing changes.
  await render(reported("new", "bypassPermissions"));
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});

test("a remembered mode that asks draws no warning", async () => {
  await render(reported("earlier", "default"));
  await fresh();
  expect(access()).toEqual({ label: "Ask before edits", warning: false });
});

test("a remembered chip from before the mode id was kept draws its label without the warning", async () => {
  localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { mode: "Bypass permissions" } }));
  await render(undefined);
  expect(access()).toEqual({ label: "Bypass permissions", warning: false });
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  // A broken value is no mode id either.
  localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { mode: "Bypass permissions", modeId: 42 } }));
  await render(undefined);
  expect(access()).toEqual({ label: "Bypass permissions", warning: false });
});
