// l10n-allow-file: test fixtures.
// The model picker's Refresh models (cx-ncc.48): it re-probes the agents' live model lists
// (`_acpmux/models {refresh: true}`, the pane's `models.refresh` action) and the open picker lists
// what came back. A host that does not serve `models.catalog` (the app today) keeps the bundled
// catalog; that is not a failed refresh.
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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
  const win = dom.window as unknown as Record<string, unknown>;
  delete win.webkit;
  delete win.cmuxAcpmuxActions;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("Refresh models re-probes the agents and the open picker lists the new model; a host without models.catalog is not an error", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useState } = await import("react");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog, resetModelCatalogForTests } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  resetModelCatalogForTests();

  // The app's host: it has no `models.catalog` op, and says so as the page host does.
  const asked: string[] = [];
  (dom.window as unknown as Record<string, unknown>).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string }) => {
          asked.push(message.method);
          return message.method === "models.catalog"
            ? { ok: false, error: { code: "native.invalid_request", origin: "native" } }
            : { ok: true, value: null };
        },
      },
    },
  };

  const harness = "codex";
  const initial = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const probedModel = { id: "gpt-7-nova", name: "GPT-7 Nova" };
  const probes: unknown[] = [];
  let pickerCatalog = "";

  function Host() {
    const [catalog, setCatalog] = useState(initial);
    // The pane's action: acpmux probes every agent again and the catalog re-reads.
    (
      window as unknown as {
        cmuxAcpmuxActions: Record<string, (params: unknown) => Promise<unknown>>;
      }
    ).cmuxAcpmuxActions = {
      "models.refresh": async (params) => {
        probes.push(params);
        setCatalog((current) =>
          current.map((entry) => (entry.id === harness ? { ...entry, models: [...entry.models, probedModel] } : entry)),
        );
      },
    };
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
      summary: { sessionId: "s", harness, turnCount: 2 },
    } as unknown as Snapshot;
    const picker = usePickerCatalog(snapshot.catalog, { harness });
    pickerCatalog = JSON.stringify(picker.catalog);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        catalogRefresh={{ status: "idle", date: picker.date, refresh: picker.refresh }}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }

  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
  expect(pickerCatalog).not.toContain(probedModel.id);

  const byLabel = (label: string) =>
    dom.window.document.querySelector<HTMLElement>(`button[aria-label="${label}"]`) ??
    [...dom.window.document.querySelectorAll<HTMLElement>("button")].find((item) => item.textContent === label);
  // The shortcut opens the compact menu, then More models opens the full list and its Refresh action.
  await act(async () => {
    dom.window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
    );
  });
  const more = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu [role=menuitem]")].find(
    (item) => item.textContent?.startsWith("More models"),
  );
  expect(more).toBeDefined();
  await act(async () => more!.click());
  const refresh = byLabel("Refresh models")!;
  expect(refresh).toBeDefined();
  await act(async () => refresh.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

  expect(probes.length).toBe(1);
  expect(pickerCatalog).toContain(probedModel.id);
  expect(asked).toContain("models.catalog");
  expect(byLabel("Refresh models")!.getAttribute("title")).not.toBe("Couldn’t refresh models");
});

test("an agent with no models yet says so and points at Refresh models, not No matching models", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <ModelPicker
        catalog={[{ id: "claude", name: "Claude Code", models: [] }]}
        harness="claude"
        label="Claude Code"
        efforts={[]}
        recents={[]}
        onLand={() => undefined}
        onEffort={() => undefined}
        catalogRefresh={{ status: "idle", refresh: () => undefined }}
      />,
    );
  });
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  const text = dom.window.document.body.textContent ?? "";
  expect(text).toContain("No models yet. Refresh to ask the agent again.");
  expect(text).not.toContain("No matching models");
});
