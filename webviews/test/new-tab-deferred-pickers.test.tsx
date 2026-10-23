// A New Tab's picker uses the same ComposerPickers path as an active chat. A typed
// model/effort/fast combo must survive the deferred chat's empty session id until the
// first real snapshot confirms the selection.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
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
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
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

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

test("a deferred New Tab combo keeps effort and fast until its chat reports a session", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const acpmux = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const sent: { method: string; value: string }[] = [];
  let reportSession: (() => void) | undefined;

  function Host() {
    const [state, setState] = useState({ sessionId: "", model: "claude-sonnet-5-5", fast: "off", effort: "medium" });
    reportSession = () => setState((current) => ({ ...current, sessionId: "deferred-1" }));
    const hasSession = state.sessionId.length > 0;
    const snapshot: Snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: acpmux,
      summary: {
        sessionId: state.sessionId,
        harness: "claude",
        model: state.model,
        turnCount: hasSession ? 0 : undefined,
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: state.effort,
            options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
          },
          ...(hasSession
            ? [
                {
                  id: "fast-mode",
                  name: "Fast mode",
                  currentValue: state.fast,
                  options: [
                    { value: "off", name: "Off" },
                    { value: "on", name: "On" },
                  ],
                },
              ]
            : []),
        ],
      },
    } as Snapshot;
    const picker = usePickerCatalog(
      snapshot.catalog,
      { harness: "claude", configOptions: snapshot.summary?.configOptions },
      [],
    );
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        holdsModePick
        onModel={(model) => {
          sent.push({ method: "model", value: model });
          setState((current) => ({ ...current, model }));
        }}
        onMode={() => undefined}
        onEffort={(configId, value) => {
          sent.push({ method: configId, value });
          setState((current) =>
            configId === "fast-mode" ? { ...current, fast: value } : { ...current, effort: value },
          );
        }}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }

  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    );
  });

  // Cmd-Ctrl-M opens the full picker; typing a query chooses the model, effort and speed together.
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true }));
  });
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]');
  expect(search).not.toBeNull();
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(search, "opus high fast");
    search!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  const row = [...host.querySelectorAll<HTMLElement>('.acpmux-mp [role="option"][data-key^="model:"]')].find(
    (candidate) => candidate.textContent?.includes("Opus 5.5"),
  );
  expect(row).not.toBeUndefined();
  await act(async () => row!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(sent).toEqual([{ method: "model", value: "claude-opus-5-5" }]);

  // The deferred New Tab has no session id and no live fast option yet. Once its first report
  // arrives, both queued values land through the same ComposerPickers mutation path.
  await act(async () => reportSession!());
  expect(sent).toEqual([
    { method: "model", value: "claude-opus-5-5" },
    { method: "effort", value: "high" },
    { method: "fast-mode", value: "on" },
  ]);
});
