// The model menu of a started chat, wired the way App.tsx wires it: ComposerPickers draws
// `applySwitch(raw, harnessSwitch.view())`, its picks go through the real HarnessSwitch, and a
// fake Codex agent answers `session/set_model` and `session/set_config_option` late, the way a
// busy agent does. Each test runs a sequence of picks and checks that the agent ends on the last
// model and effort the person picked, and that the menu's check agrees with it.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

setDefaultTimeout(60_000);

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
  "PointerEvent",
  "FocusEvent",
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
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function press(element: Element) {
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
    element.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
}

async function settle() {
  for (let turn = 0; turn < 5; turn += 1) await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
}

const MODELS = {
  "gpt-6.1-sol": { name: "GPT-6.1 Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], def: "low" },
  "gpt-6-astra": { name: "GPT-6 Astra", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], def: "medium" },
  "gpt-6-luna": { name: "GPT-6 Luna", efforts: ["low", "medium", "high", "xhigh", "max"], def: "medium" },
} as const;
type ModelId = keyof typeof MODELS;

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// A Codex-like agent: a model switch lands only when `deliver()` runs, and resets the effort to the
/// new model's default (codex-acp reports the new option list after the switch).
function fakeAgent(quirks: { alias?: Record<string, string>; refuse?: string[] } = {}) {
  const state = { model: "gpt-6.1-sol" as ModelId, effort: "low" };
  const queue: (() => void)[] = [];
  const listeners = new Set<() => void>();
  const changed = () => {
    for (const listener of listeners) listener();
  };
  const raw = (): Snapshot =>
    ({
      type: "snapshot",
      protocolVersion: 1,
      sessionId: "s1",
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: [
        {
          id: "codex",
          name: "Codex",
          models: Object.entries(MODELS).map(([id, model]) => ({
            id,
            name: model.name,
            efforts: [...model.efforts],
            defaultEffort: model.def,
            ...(quirks.alias?.[id] ? { release: quirks.alias[id] } : {}),
          })),
        },
      ],
      summary: {
        sessionId: "s1",
        harness: "codex",
        model: quirks.alias?.[state.model] ?? state.model,
        turnCount: 1,
        configOptions: [
          {
            id: "reasoning_effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: state.effort,
            options: MODELS[state.model].efforts.map((value) => ({ value })),
          },
        ],
      },
    }) as Snapshot;
  return {
    state,
    raw,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    setModel(model: string) {
      return new Promise<void>((resolve, reject) => {
        queue.push(() => {
          if (quirks.refuse?.includes(model)) {
            reject(new Error("model not available"));
            return;
          }
          const next = model as ModelId;
          if (!MODELS[next]) throw new Error(`unknown model ${model}`);
          state.model = next;
          if (!(MODELS[next].efforts as readonly string[]).includes(state.effort)) state.effort = MODELS[next].def;
          changed();
          resolve();
        });
      });
    },
    setConfig(_configId: string, value: string) {
      return new Promise<void>((resolve) => {
        queue.push(() => {
          if ((MODELS[state.model].efforts as readonly string[]).includes(value)) state.effort = value;
          changed();
          resolve();
        });
      });
    },
    /// The agent answers every request it has, in order.
    async deliver() {
      while (queue.length) await act(async () => queue.shift()!());
      await settle();
    },
  };
}

async function mount(quirks: Parameters<typeof fakeAgent>[0] = {}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { HarnessSwitch, applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const agent = fakeAgent(quirks);
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect({
    turnRunning: () => false,
    shown: () => ({ sessionId: "s1", harness: "codex", model: agent.state.model, empty: false }),
    create: async () => undefined,
    leave: () => undefined,
    open: async () => undefined,
    send: async () => undefined,
    setModel: (model) => agent.setModel(model),
    setMode: async () => undefined,
    setConfig: (configId, value) => agent.setConfig(configId, value),
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as import("../src/agent-session/acpmux/harnessSwitch").SwitchPort);
  const client = new QueryClient();
  const render = () => {
    const raw = agent.raw();
    harnessSwitch.reconcile(raw);
    const snapshot = applySwitch(raw, harnessSwitch.view(), raw.catalog);
    root!.render(
      <QueryClientProvider client={client}>
        <ComposerPickers
          snapshot={snapshot}
          onModel={(model) => {
            const live = agent.raw().summary!;
            void harnessSwitch.pickModel(model, { sessionId: "s1", model: live.model });
          }}
          onMode={() => undefined}
          onEffort={(configId, value) => {
            const live = agent.raw().summary!;
            const option = live.configOptions?.find((item) => item.id === configId) ?? live.configOptions?.[0];
            harnessSwitch.pickConfig(option!.id, value, {
              sessionId: "s1",
              current: option?.currentValue ?? undefined,
            });
          }}
          onHarness={() => undefined}
          fork
          showPlan={false}
        />
      </QueryClientProvider>,
    );
  };
  root = createRoot(host);
  harnessSwitch.subscribe(() => render());
  agent.subscribe(() => render());
  await act(async () => render());
  return { agent, render };
}

const menu = () => dom.window.document.querySelector<HTMLElement>(".acpmux-cols");
async function openMenu() {
  if (menu()) return;
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await settle();
  expect(menu()).not.toBeNull();
}
async function closeMenu() {
  await act(async () => {
    dom.window.document.activeElement?.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
  });
  await settle();
}
const modelRow = (name: string) =>
  [...(menu()?.querySelectorAll<HTMLElement>('[id^="acpmux-cols-model-"]') ?? [])].find((row) =>
    row.textContent?.includes(name),
  );
const levelRow = (label: string) =>
  [...(menu()?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]') ?? [])].find(
    (row) => row.querySelector(".acpmux-cols-name")?.textContent === label,
  );
const checkedLevel = () =>
  [...(menu()?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"][aria-checked="true"]') ?? [])].map(
    (row) => row.querySelector(".acpmux-cols-name")?.textContent,
  );
async function pickModel(name: string) {
  const row = modelRow(name);
  expect(row, name).toBeDefined();
  await act(async () => press(row!));
  await settle();
}
async function pickLevel(label: string) {
  const row = levelRow(label);
  expect(row, label).toBeDefined();
  await act(async () => press(row!));
  await settle();
}

test("effort picks on the running model reach the agent", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickLevel("High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "high" });
  await pickLevel("Medium");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "medium" });
  expect(checkedLevel()).toEqual(["Medium"]);
});

test("a model pick, then an effort pick in the same open menu after the agent switched", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickModel("GPT-6 Astra");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6-astra");
  await pickLevel("Extra High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-astra", effort: "xhigh" });
  await pickLevel("Medium");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-astra", effort: "medium" });
  expect(checkedLevel()).toEqual(["Medium"]);
});

test("an effort pick while the model switch is still in flight lands on the new model", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickModel("GPT-6 Astra");
  await pickLevel("High");
  await agent.deliver();
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-astra", effort: "high" });
});

test("model, effort, then back to the first model and another effort, menu reopened between", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickModel("GPT-6 Astra");
  await agent.deliver();
  await closeMenu();
  await openMenu();
  await pickLevel("Max");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-astra", effort: "max" });
  await pickModel("GPT-6.1 Sol");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6.1-sol");
  await pickLevel("Low");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "low" });
  await closeMenu();
  await openMenu();
  await pickLevel("High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "high" });
  await pickModel("GPT-6 Luna");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6-luna");
});

test("quick picks: two models then an effort before the agent answers anything", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickModel("GPT-6 Astra");
  await pickModel("GPT-6 Luna");
  await pickLevel("High");
  await agent.deliver();
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-luna", effort: "high" });
  // The menu still takes picks afterwards.
  await pickLevel("Low");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-luna", effort: "low" });
  await pickModel("GPT-6.1 Sol");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6.1-sol");
});

test("after a lost race the menu still takes effort and model picks", async () => {
  const { agent } = await mount();
  await openMenu();
  await pickModel("GPT-6 Astra");
  await pickModel("GPT-6 Luna");
  await pickLevel("High");
  await agent.deliver();
  await agent.deliver();
  await pickLevel("Max");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-luna", effort: "max" });
  await closeMenu();
  await openMenu();
  await pickLevel("Medium");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-luna", effort: "medium" });
  await pickModel("GPT-6.1 Sol");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6.1-sol");
});

test("an alias row whose release the agent reports is the running row: effort picks stay on it", async () => {
  const { agent } = await mount({ alias: { "gpt-6-astra": "gpt-6-astra-2026-10" } });
  await openMenu();
  await pickModel("GPT-6 Astra");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6-astra");
  await closeMenu();
  await openMenu();
  await pickLevel("High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-astra", effort: "high" });
  await pickModel("GPT-6 Luna");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6-luna");
  await pickLevel("Low");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6-luna", effort: "low" });
});

test("a refused model pick leaves the menu working", async () => {
  const { agent } = await mount({ refuse: ["gpt-6-astra"] });
  await openMenu();
  await pickModel("GPT-6 Astra");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6.1-sol");
  await closeMenu();
  await openMenu();
  await pickLevel("High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "high" });
  await pickModel("GPT-6 Luna");
  await agent.deliver();
  expect(agent.state.model).toBe("gpt-6-luna");
});

test("a refused model pick in the same open menu leaves effort picks working", async () => {
  const { agent } = await mount({ refuse: ["gpt-6-astra"] });
  await openMenu();
  await pickModel("GPT-6 Astra");
  await agent.deliver();
  await pickModel("GPT-6.1 Sol");
  await agent.deliver();
  await pickLevel("High");
  await agent.deliver();
  expect(agent.state).toEqual({ model: "gpt-6.1-sol", effort: "high" });
});
