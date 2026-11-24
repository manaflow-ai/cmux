// The composer's model picker, setup state, and Connect actions in the DOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import { selectFamilyOnReturn, type CloudServed } from "../src/agent-session/acpmux/cloudServed";
import type { ModelPickerProps } from "../src/agent-session/acpmux/modelPickerLayout";

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
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu, .acpmux-cols")) popup.remove();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const runnableFamilies = ["claude", "codex"];

const catalog = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
    ],
  },
  { id: "codex", name: "Codex", models: [{ id: "gpt-6.1-sol", name: "GPT-6.1 Sol" }] },
  { id: "gemini", name: "Gemini", models: [{ id: "local-model", name: "Local model" }] },
  { id: "openrouter", name: "OpenRouter", models: [{ id: "router-model", name: "Router model" }] },
  { id: "grok-build", name: "Grok Build", models: [] },
  { id: "opencode", name: "OpenCode", models: [] },
  { id: "pi", name: "Pi", models: [] },
];
const allFamilies = (full: boolean) =>
  catalog.map((entry) => (full || entry.id !== "grok-build" ? entry.name : "Grok Build (build)"));

async function mount({
  brands = [],
  cloud,
  selected = catalog[0],
  full = false,
  entries = catalog,
  signedOut,
  onSetUpPick,
  addAccount,
  fastMode,
}: {
  brands?: readonly string[];
  cloud?: { served?: CloudServed; openSettings?(family: string): void };
  selected?: (typeof catalog)[number] | null;
  full?: boolean;
  entries?: ModelPickerProps["catalog"];
  signedOut?: ModelPickerProps["signedOut"];
  onSetUpPick?: ModelPickerProps["onSetUpPick"];
  addAccount?: import("../src/agent-session/acpmux/chatAccounts").ChatAccounts["add"];
  fastMode?: ModelPickerProps["fastMode"];
} = {}) {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const { CloudServedContext } = await import("../src/agent-session/acpmux/cloudServed");
  const { callNative } = await import("../src/agent-session/acpmux/callNative");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const pressed: (string | undefined)[] = [];
  const settingsCalls: Record<string, unknown>[] = [];
  (dom.window as unknown as Window).cmuxAcpmuxActions = {
    "cloud.connect": async (params) => void settingsCalls.push(params),
  };
  const landed: string[] = [];
  let reads = 0;
  root = createRoot(host);
  const render = async (state = cloud) => {
    const row = { brands, connected: false, onConnect: (brand?: string) => void pressed.push(brand) };
    await act(async () =>
      root!.render(
        <ChatAccountsContext.Provider
          value={
            addAccount
              ? { add: addAccount, list: async () => ({ accounts: [] }), set: async () => undefined }
              : undefined
          }
        >
          <CloudServedContext.Provider
            value={
              state && {
                ...state,
                refresh: () => void (reads += 1),
                openSettings: state.openSettings ?? ((family) => void callNative("cloud.connect", { family })),
              }
            }
          >
            <ModelPicker
              catalog={entries}
              harness={selected?.id}
              model={selected?.models[0]?.id}
              label={selected?.models[0]?.name ?? "Model"}
              efforts={[]}
              fastMode={fastMode}
              recents={[]}
              quick={full ? undefined : {}}
              onLand={(model) => void landed.push(model)}
              onCombo={({ model }) => void landed.push(model)}
              onEffort={() => undefined}
              onHarness={() => undefined}
              signedOut={signedOut}
              onSetUpPick={onSetUpPick}
              onLogIn={(harness) => void pressed.push(harness)}
              claudeConnect={row.brands.length ? row : undefined}
            />
          </CloudServedContext.Provider>
        </ChatAccountsContext.Provider>,
      ),
    );
  };
  await render();
  const open = async () => {
    await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  };
  return { pressed, settingsCalls, landed, reads: () => reads, open, render };
}

const doc = () => dom.window.document;
const connectRows = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-connect-claude-row")];
const rail = () => [...popup().querySelectorAll<HTMLElement>(".acpmux-mp-harness, .acpmux-cols-tab[role=tab]")];
const tabName = (entry: HTMLElement) =>
  entry.getAttribute("aria-label") ?? entry.querySelector(".sr-only")?.textContent;
const tab = (name: string) => rail().find((entry) => tabName(entry) === name);
const families = () =>
  rail()
    .map(tabName)
    .filter((name) => name !== "Starred");
const action = (label: string) =>
  [...popup().querySelectorAll<HTMLElement>('button, [role="button"]')].find(
    (row) => (row.querySelector(".acpmux-cols-name, .acpmux-menu-label")?.textContent ?? row.textContent) === label,
  );

const popup = () => doc().querySelector<HTMLElement>(".acpmux-cols, .acpmux-mp")!;
const field = () => popup().querySelector<HTMLInputElement>("input[type=search]")!;

async function key(target: EventTarget, value: string) {
  await act(
    async () => void target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: value, bubbles: true })),
  );
}

async function search(value: string) {
  const input = field();
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

test("closed, the picker reads nothing; each opening reads what serves Cloud again", async () => {
  const picker = await mount({ cloud: {} });
  expect(picker.reads()).toBe(0);
  await picker.open();
  expect(picker.reads()).toBe(1);
  await act(
    async () => void doc().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
  );
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  await picker.open();
  expect(picker.reads()).toBeGreaterThanOrEqual(2);
});

test("Claude and Codex both unserved: each section leads with its Connect row, which names its own section", async () => {
  const picker = await mount({ brands: ["claude", "openai"] });
  await picker.open();
  expect(connectRows().map((row) => row.textContent)).toEqual([expect.stringContaining("Claude Code")]);
  await act(async () => connectRows()[0]!.closest<HTMLElement>(".acpmux-cols-connect")!.click());
  expect(picker.pressed).toEqual(["claude"]);
  await picker.open();
  await act(async () => tab("Codex")?.click());
  await act(async () => tab("Codex")?.dispatchEvent(new dom.window.MouseEvent("mousemove", { bubbles: true })));
  expect(connectRows().map((row) => row.textContent)).toEqual([expect.stringContaining("Codex")]);
});

test("only Codex unserved: the Claude section shows no Connect row", async () => {
  const picker = await mount({ brands: ["openai"] });
  await picker.open();
  expect(connectRows()).toEqual([]);
});

const cloudState = (families: CloudServed["families"]) => ({ served: { runnableFamilies, families } });
function expectSettingsOpened(picker: Awaited<ReturnType<typeof mount>>, family: string) {
  expect(picker.settingsCalls).toEqual([{ family }]);
  expect(picker.pressed).toEqual([]);
  expect(doc().querySelector('.acpmux-cols[data-open], .acpmux-mp[data-open], [role="dialog"]')).toBeNull();
  expect(host.querySelector('[data-menu="Model"]')?.getAttribute("aria-expanded")).toBe("false");
}

for (const full of [false, true]) {
  const form = full ? "full" : "column";

  test(`Cloud uses This Mac's ${form} picker rail and the served family's models`, async () => {
    const picker = await mount({ full, signedOut: { claude: "claude login" } });
    await picker.open();
    const localRail = families();
    expect(localRail).toEqual(allFamilies(full));
    await picker.render(cloudState({ claude: true, codex: false }));
    expect(families()).toEqual(localRail);
    expect(tab("Claude Code")?.getAttribute("aria-selected")).toBe("true");
    expect(popup().textContent).toContain("Opus 5.5");

    await search("Local model");
    expect(popup().textContent).not.toContain("Local model");
    await search("GPT");
    expect(popup().textContent).not.toContain("GPT-6.1 Sol");
    await search("Sonnet");
    expect(popup().textContent).toContain("Sonnet 5.5");
    await key(field(), "Enter");
    expect(picker.landed).toEqual(["claude-sonnet-5-5"]);
  });

  test(`the ${form} picker reuses the setup row to open Cloud Settings for Claude`, async () => {
    const picker = await mount({ full, signedOut: { claude: "claude login" } });
    await picker.open();
    const login = action("Log In")!;
    expect(login).toBeDefined();

    await picker.render(cloudState({ claude: false, codex: true }));
    expect(tab("Claude Code")?.title).toContain("Not connected");
    // The local picker's models keep its size, muted and not pickable; the Connect row leads the list.
    expect(popup().textContent).toContain("Opus 5.5");
    const connect = action("Connect Claude Code")!;
    expect(connect).toBeDefined();
    const list = connect.parentElement!;
    expect(list.hasAttribute("data-locked")).toBe(true);
    expect(list.querySelector('[role="button"], button, [role="option"]')).toBe(connect);
    const opus = [...list.querySelectorAll<HTMLElement>('[role="option"]')].find((row) =>
      row.textContent?.includes("Opus 5.5"),
    );
    if (opus) expect(opus.getAttribute("aria-disabled") === "true" || opus.hasAttribute("disabled")).toBe(true);
    await act(async () => connect.click());
    expectSettingsOpened(picker, "claude");
    const reads = picker.reads();
    await picker.render(cloudState({ claude: true, codex: true }));
    await picker.open();
    expect(picker.reads()).toBe(reads + 1);
    expect(popup().textContent).toContain("Opus 5.5");
  });

  test(`a family that cannot run on Cloud keeps its ${form} connect row`, async () => {
    const picker = await mount({ full, cloud: cloudState({ claude: true, codex: true }), selected: catalog[3]! });
    await picker.open();
    expect(tab("OpenRouter")?.title).toContain("Not connected");
    expect(popup().textContent).not.toContain("Router model");
    const connect = action("Connect OpenRouter")!;
    expect(connect).toBeDefined();
    // The cause is the Connect row's second line, spaced as "Not connected" is.
    expect(connect.contains(popup().querySelector("[data-cloud-coming-soon]"))).toBe(true);
    expect(popup().textContent).toContain("Runs on Cloud soon");
    await act(async () => connect.click());
    expectSettingsOpened(picker, "openrouter");
  });

  test(`unknown Cloud state and This Mac have the same ${form} picker markup`, async () => {
    const picker = await mount({ signedOut: { claude: "claude login" }, full });
    await picker.open();
    const local = popup().innerHTML;
    await picker.render({});
    expect(popup().innerHTML).toBe(local);
  });
}

test("a late Cloud answer retains the selected tab without offering its models", async () => {
  const picker = await mount({ cloud: {}, selected: catalog[2]! });
  await picker.open();
  expect(tab("Gemini")?.getAttribute("aria-selected")).toBe("true");
  await picker.render(cloudState({ claude: true, codex: false }));
  expect(tab("Gemini")?.getAttribute("aria-selected")).toBe("true");
  expect(popup().textContent).not.toContain("Local model");
  expect(picker.landed).toEqual([]);
  expect(host.querySelector('[data-menu="Model"]')?.textContent).toContain("Local model");
});

test("the Cloud rail selects a served model even if its harness is not installed on this Mac", async () => {
  const picker = await mount({
    cloud: cloudState({ claude: true, codex: true }),
    entries: [catalog[0]!, { ...catalog[1]!, notInstalled: true, pickable: false }, catalog[2]!],
  });
  await picker.open();
  await key(field(), "ArrowLeft");
  await key(field(), "ArrowDown");
  expect(tab("Gemini")?.getAttribute("aria-selected")).toBe("true");
  await key(field(), "ArrowDown");
  expect(tab("Codex")?.getAttribute("aria-selected")).toBe("true");
  await key(field(), "ArrowRight");
  await key(field(), "Enter");
  expect(picker.landed).toEqual(["gpt-6.1-sol"]);
});

test("Codex requests model setup with its family", async () => {
  const picker = await mount({ cloud: cloudState({ claude: true, codex: false }), selected: catalog[1]! });
  await picker.open();
  await act(async () => action("Connect Codex")!.click());
  expectSettingsOpened(picker, "codex");
});

test("Gemini requests model setup even when the harness has a local sign-in", async () => {
  const picker = await mount({
    cloud: cloudState({ claude: true, codex: true }),
    selected: catalog[2]!,
    entries: catalog.map((entry) => (entry.id === "gemini" ? { ...entry, auth: { login: "gemini" } } : entry)),
  });
  await picker.open();
  await act(async () => action("Connect Gemini")!.click());
  expectSettingsOpened(picker, "gemini");
});

test("a hosted endpoint is selectable only when the host serves its exact harness", async () => {
  const endpoint = { id: "deepseek", name: "DeepSeek", models: [{ id: "byo/deepseek-chat", name: "DeepSeek Chat" }] };
  const picker = await mount({
    entries: [...catalog, endpoint],
    cloud: { served: { runnableFamilies, families: { claude: true }, servedHarnesses: ["deepseek"] } },
  });
  await picker.open();
  await act(async () => tab("DeepSeek")!.click());
  expect(action("Connect DeepSeek")).toBeUndefined();
  expect(popup().textContent).toContain("DeepSeek Chat");
});

test("a partial Cloud answer leaves an undecided runnable family on its local behavior", async () => {
  const picker = await mount({ cloud: cloudState({ claude: true }) });
  await picker.open();
  expect(families()).toEqual(allFamilies(false));
  await act(async () => tab("Codex")!.click());
  expect(popup().textContent).toContain("GPT-6.1 Sol");
  expect(action("Connect Codex")).toBeUndefined();
});

test("an unsupported custom family requests model setup with its family", async () => {
  const pi = catalog.find((entry) => entry.id === "pi")!;
  const picker = await mount({
    cloud: cloudState({ claude: true, codex: true }),
    selected: pi,
    addAccount: async () => undefined,
  });
  await picker.open();
  await act(async () => action("Connect Pi")!.click());
  expectSettingsOpened(picker, "pi");
});

for (const full of [false, true]) {
  test.each([
    [undefined, "Not connected"],
    ["none", "Not connected"],
    ["signedOut", "Sign in again"],
    ["off", "Turned off in Settings"],
  ] as const)("locked family shows the %s cause with its models (full: " + full + ")", async (reason, label) => {
    const picker = await mount({
      cloud: {
        served: { runnableFamilies, families: { claude: false }, ...(reason ? { reasons: { claude: reason } } : {}) },
      },
      full,
    });
    await picker.open();
    const row = popup().querySelector("[data-cloud-connect]")!;
    expect(row.children.length > 0).toBe(true);
    expect(row.textContent).toContain("Connect Claude Code");
    expect(row.textContent).toContain(label);
    expect(popup().querySelector("[data-locked]")?.textContent).toContain("Opus 5.5");
  });
}

test.each([false, true])("a returned ready family respects a later pick (changed: %s)", async (changed) => {
  let afterReturn: (() => void) | undefined;
  let pick = { harness: "codex", revision: [0] };
  const selected: string[] = [];
  const picker = await mount({
    selected: catalog[1],
    cloud: {
      served: { runnableFamilies, families: { claude: false, codex: true } },
      openSettings: (family) => {
        afterReturn = selectFamilyOnReturn(
          family,
          () => pick,
          () => selected.push(family),
        );
      },
    },
  });
  await picker.open();
  await act(async () => tab("Claude Code")!.click());
  await act(async () => action("Connect Claude Code")!.click());
  expect(afterReturn).toBeDefined();
  if (changed) pick = { ...pick, revision: [1] };
  await picker.render({ served: { runnableFamilies, families: { claude: true, codex: true } } });
  afterReturn?.();
  expect(selected).toEqual(changed ? [] : ["claude"]);
});

test("the full picker keeps its Fast control visible and disabled for a locked family", async () => {
  const picks: string[] = [];
  const picker = await mount({
    full: true,
    cloud: { served: { runnableFamilies, families: { claude: false } } },
    fastMode: {
      name: "Fast",
      currentValue: "off",
      onValue: "on",
      offValue: "off",
      onLabel: "On",
      offLabel: "Off",
      onPick: (value) => picks.push(value),
    },
  });
  await picker.open();
  const fast = () => popup().querySelector<HTMLButtonElement>(".acpmux-mp-fast")!;
  expect(fast().disabled).toBe(true);
  await act(async () => fast().click());
  expect(picks).toEqual([]);
  await picker.render({ served: { runnableFamilies, families: { claude: true } } });
  expect(fast().disabled).toBe(false);
  await act(async () => fast().click());
  expect(picks).toEqual(["on"]);
});
