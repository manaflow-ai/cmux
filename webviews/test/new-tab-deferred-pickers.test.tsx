// A New Tab's picker uses the same ComposerPickers path as an active chat. A typed
// model/effort/fast combo picked before the deferred chat has a session (an empty id) must
// survive that chat reporting its real id, and still drop when the pane moves to another chat.
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
type Sent = { method: string; value: string };

/// A New Tab pane as harnessSwitch draws it: before acpmux reports the deferred chat's session,
/// the summary has an empty id and names the picked model as both drawn and confirmed. Once the
/// session opens, its id arrives with the model the agent runs, then the model the held pick set.
async function mountNewTab({ effortBeforeSession }: { effortBeforeSession: boolean }) {
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
  const sent: Sent[] = [];
  type State = { sessionId: string; model: string; confirmedModel: string; fast: string; effort: string };
  let update: ((change: (state: State) => State) => void) | undefined;

  function Host() {
    const [state, setState] = useState<State>({
      sessionId: "",
      model: "claude-sonnet-5-5",
      confirmedModel: "claude-sonnet-5-5",
      fast: "off",
      effort: "medium",
    });
    update = setState;
    const hasSession = state.sessionId.length > 0;
    const effortOption = {
      id: "effort",
      name: "Effort",
      category: "thought_level",
      currentValue: state.effort,
      options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
    };
    const fastOption = {
      id: "fast-mode",
      name: "Fast mode",
      currentValue: state.fast,
      options: [
        { value: "off", name: "Off" },
        { value: "on", name: "On" },
      ],
    };
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
        confirmedModel: state.confirmedModel,
        turnCount: hasSession ? 0 : undefined,
        configOptions: hasSession ? [effortOption, fastOption] : effortBeforeSession ? [effortOption] : [],
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
          // Before a session, the switch draws the pick back as the model at once.
          setState((current) =>
            current.sessionId ? { ...current, model } : { ...current, model, confirmedModel: model },
          );
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
  const pickCombo = async (query: string, label: string) => {
    // Cmd-Ctrl-M opens the full picker; typing a query chooses the model, effort and speed together.
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true }));
    });
    const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]');
    expect(search).not.toBeNull();
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setter.call(search, query);
      search!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    const row = [...host.querySelectorAll<HTMLElement>('.acpmux-mp [role="option"][data-key^="model:"]')].find(
      (candidate) => candidate.textContent?.includes(label),
    );
    expect(row).not.toBeUndefined();
    await act(async () => row!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  };
  const set = async (change: (state: State) => State) => act(async () => update!(change));
  return { sent, pickCombo, set };
}

test("a New Tab combo's effort goes to the switch at once and its Fast pick lands once the chat reports a session", async () => {
  const { sent, pickCombo, set } = await mountNewTab({ effortBeforeSession: true });
  await pickCombo("opus high fast", "Opus 5.5");
  // The effort the agent's profile offers goes to the switch now, which holds it for the first turn.
  expect(sent).toEqual([
    { method: "model", value: "claude-opus-5-5" },
    { method: "effort", value: "high" },
  ]);
  // The session opens on the model the agent runs, then the held pick lands: Fast mode follows.
  await set((state) => ({ ...state, sessionId: "deferred-1", confirmedModel: "claude-sonnet-5-5" }));
  await set((state) => ({ ...state, confirmedModel: state.model }));
  expect(sent).toEqual([
    { method: "model", value: "claude-opus-5-5" },
    { method: "effort", value: "high" },
    { method: "fast-mode", value: "on" },
  ]);
});

test("a New Tab combo with no effort offered before the session lands its effort and Fast once the chat runs the model", async () => {
  const { sent, pickCombo, set } = await mountNewTab({ effortBeforeSession: false });
  await pickCombo("opus high fast", "Opus 5.5");
  expect(sent).toEqual([{ method: "model", value: "claude-opus-5-5" }]);
  // The session first reports the model the agent started on; the combo waits rather than dropping.
  await set((state) => ({ ...state, sessionId: "deferred-1", confirmedModel: "claude-sonnet-5-5" }));
  expect(sent).toEqual([{ method: "model", value: "claude-opus-5-5" }]);
  await set((state) => ({ ...state, confirmedModel: state.model }));
  expect(sent).toEqual([
    { method: "model", value: "claude-opus-5-5" },
    { method: "effort", value: "high" },
    { method: "fast-mode", value: "on" },
  ]);
});

test("a New Tab combo belongs to the first session its chat reports: another session after it drops the combo", async () => {
  const { sent, pickCombo, set } = await mountNewTab({ effortBeforeSession: false });
  await pickCombo("opus high fast", "Opus 5.5");
  await set((state) => ({ ...state, sessionId: "deferred-1", confirmedModel: "claude-sonnet-5-5" }));
  // The pane moves on to another chat before the pick reached the model: nothing lands there.
  await set((state) => ({ ...state, sessionId: "other-chat" }));
  await set((state) => ({ ...state, confirmedModel: state.model }));
  expect(sent).toEqual([{ method: "model", value: "claude-opus-5-5" }]);
});
