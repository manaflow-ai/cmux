// A New Tab's picker uses the same ComposerPickers path as an active chat. A typed
// model/effort/fast combo picked before the deferred chat has a session goes into the harness
// switch's config, so a prompt sent right after it runs its first turn on the whole combo: the
// switch applies the picks, mapped onto the options the opened session names, before the prompt.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useSyncExternalStore } from "react";
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
  "ResizeObserver",
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
type Option = NonNullable<NonNullable<Snapshot["summary"]>["configOptions"]>[number];

const effortOption = (id = "effort", values = ["low", "medium", "high"]): Option => ({
  id,
  name: "Effort",
  category: "thought_level",
  currentValue: "medium",
  options: values.map((value) => ({ value, name: value })),
});
const fastOption = (id = "fast-mode", values: string[] = ["off", "on"]): Option => ({
  id,
  name: "Fast mode",
  currentValue: values[0],
  options: values.map((value) => ({ value, name: value })),
});

/// A New Tab pane as App wires it: its chips draw the harness switch's view of the page's empty
/// summary, and a pick starts the deferred chat (`chat.new {deferred}`) and goes to the switch
/// (`chat.model`, `chat.effort`). The port records what reaches acpmux once the session opens with
/// `opened` as its options; the page's summary then reports that session (its id, harness, model and
/// the values set on it), so the composer's after-open fallbacks run and any late or second send
/// shows on the wire.
async function mountNewTab({ opened, model = "claude-sonnet-5-5" }: { opened: Option[]; model?: string }) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { HarnessSwitch, applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const { HarnessProfiles } = await import("../src/agent-session/acpmux/harnessProfiles");
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((choice) => ({ id: choice.id, name: choice.name })),
  })) as Snapshot["catalog"];
  // No session of this harness ran here before: the page knows none of its options.
  const profiles = new HarnessProfiles(() => undefined);
  const wire: string[] = [];
  let open = false;
  let started = "claude";
  let running = model;
  // The session's options as it reports them: each set value becomes the option's current one.
  const options = opened.map((option) => ({ ...option }));
  const store = new HarnessSwitch();
  store.connect({
    turnRunning: () => false,
    shown: () => (open ? { sessionId: "s-1", harness: started, empty: true, configOptions: options } : undefined),
    create: async (harness: string) => {
      started = harness;
      wire.push(`new ${harness}`);
      return "s-1";
    },
    leave: () => undefined,
    open: async (sessionId: string) => {
      open = true;
      return sessionId;
    },
    send: async (text: string) => void wire.push(`prompt ${text}`),
    setModel: async (modelId: string) => {
      wire.push(`model ${modelId}`);
      running = modelId;
    },
    setMode: async () => undefined,
    setConfig: async (configId: string, value: string) => {
      wire.push(`${configId}=${value}`);
      const option = options.find((candidate) => candidate.id === configId);
      if (option) option.currentValue = value;
    },
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  const raw = (): Snapshot =>
    ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog,
      summary: open
        ? {
            sessionId: "s-1",
            harness: started,
            model: running,
            turnCount: 0,
            configOptions: options.map((o) => ({ ...o })),
          }
        : { sessionId: "", harness: "claude", model, turnCount: 0 },
    }) as Snapshot;
  // The page's chat.new names the harness its chips draw: the switch's, once a pick made one. Once
  // the chat has its session, App's chips start nothing (`start` in DefaultComposerChips).
  const start = () => {
    if (!open) void store.switchTo(store.view().intent?.harness ?? "claude", "/tmp/project", { deferred: true });
  };
  // App's chat.model and chat.effort: held during the switch, else sent to the open session.
  const live = () => (open ? { sessionId: "s-1" } : undefined);

  function Host() {
    const view = useSyncExternalStore(store.subscribe, store.view);
    const snapshot = applySwitch(raw(), view, catalog, profiles);
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
        onModel={(modelId) => {
          start();
          void store.pickModel(modelId, live());
        }}
        onMode={() => undefined}
        onEffort={(configId, value) => {
          start();
          store.pickConfig(configId, value, live());
        }}
        // App's chat.new for a pick of another harness: a deferred switch carrying the combo.
        onHarness={(harness, picked, options) =>
          void store.switchTo(harness, "/tmp/project", {
            deferred: true,
            ...(picked ? { model: picked } : {}),
            ...(options ? { options } : {}),
          })
        }
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
  // Return right after the pick (App's chat.new, then chat.send): the prompt queues on the switch,
  // which opens the chat, applies the picks and then sends it.
  const send = async (text: string) =>
    act(async () => {
      start();
      void store.send(text);
      for (let turn = 0; turn < 5; turn++) await new Promise((done) => setTimeout(done, 0));
    });
  return { wire, pickCombo, send };
}

test("a New Tab combo's effort and Fast reach the chat before the prompt sent right after it", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption(), fastOption()] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "effort=high", "fast-mode=on", "prompt hello"]);
});

test("a New Tab combo for the model already shown still carries its effort into the first turn", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption(), fastOption()] });
  await pickCombo("sonnet high", "Sonnet 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "effort=high", "prompt hello"]);
});

test("a held New Tab combo takes the opened session's own option names and values", async () => {
  // A harness that names its effort another way and its Fast mode with true/false.
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["false", "true"])],
  });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual([
    "new claude",
    "model claude-opus-5-5",
    "reasoning_effort=high",
    "fast_mode=true",
    "prompt hello",
  ]);
});

test("a held Fast pick the opened session does not offer is not sent", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption()] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "effort=high", "prompt hello"]);
});

test("a session that reports no options takes none of the held picks", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "prompt hello"]);
});

test("a held effort the opened session does not offer is not sent, and no other level stands in", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("effort", ["low", "medium"]), fastOption()],
  });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "fast-mode=on", "prompt hello"]);
});

// Codex review of #24509: a combo for another harness sent only its model into the switch, so the
// first prompt ran without its effort and Fast (they followed after the first turn).
test("a New Tab combo for another harness carries its effort and Fast into that chat's first turn", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["false", "true"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "fast_mode=true", "prompt hello"]);
});

test("a combo back to the harness still on screen sends its held options to that session, after its model", async () => {
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const wire: string[] = [];
  const store = new HarnessSwitch();
  store.connect({
    turnRunning: () => true,
    shown: () => ({
      sessionId: "s-0",
      harness: "claude",
      model: "claude-sonnet-5-5",
      empty: false,
      configOptions: [effortOption("reasoning_effort"), fastOption("fast_mode", ["false", "true"])],
    }),
    create: async () => undefined,
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    setModel: async (modelId: string) => void wire.push(`model ${modelId}`),
    setMode: async () => undefined,
    setConfig: async (configId: string, value: string) => void wire.push(`${configId}=${value}`),
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  // A turn streams: a pick of Codex waits for the next prompt, then a combo picks Claude again.
  void store.switchTo("codex");
  wire.length = 0;
  void store.switchTo("claude", undefined, {
    model: "claude-opus-5-5",
    options: { effort: "high", "fast-mode": "on" },
  });
  await new Promise((done) => setTimeout(done, 0));
  expect(store.view().intent).toBeUndefined();
  expect(wire).toEqual(["model claude-opus-5-5", "reasoning_effort=high", "fast_mode=true"]);
});

// Codex review of #24509 at 348093f4: a tiered Fast option (standard, fast, ultrafast) lists no
// on-like value, so a combo's generic Fast on was dropped and Fast came only after the first turn.
test("a combo's Fast reaches a tiered Fast option as its fast tier, never ultrafast, before the first prompt", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["standard", "fast", "ultrafast"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "fast_mode=fast", "prompt hello"]);
});

test("a generic Fast on or off takes the option's own spelling, and on never becomes a higher tier", async () => {
  const { heldOptionPick } = await import("../src/agent-session/acpmux/heldOptions");
  const tiered = [fastOption("fast_mode", ["standard", "fast", "ultrafast"])];
  expect(heldOptionPick("fast-mode", "on", tiered)).toEqual({ configId: "fast_mode", value: "fast" });
  expect(heldOptionPick("fast-mode", "off", tiered)).toEqual({ configId: "fast_mode", value: "standard" });
  // Only a higher tier past standard: nothing stands in for plain fast.
  expect(heldOptionPick("fast-mode", "on", [fastOption("fast_mode", ["standard", "ultrafast"])])).toBeUndefined();
  expect(heldOptionPick("fast-mode", "on", [fastOption("fast", ["false", "true"])])).toEqual({
    configId: "fast",
    value: "true",
  });
});
