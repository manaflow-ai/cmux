import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
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
  "ResizeObserver",
  "InputEvent",
  "StorageEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
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
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    InputEvent: dom.window.InputEvent,
    StorageEvent: dom.window.StorageEvent,
  });
  // The DOM constructors the composer's menus read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(
    ".acpmux-cols, .acpmux-quick-menu, .ui-context-menu-backdrop",
  ))
    popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

// Leo 2026-11-08 (a video of the composer's model menu opening with no models): "why is there no
// models … this shouldn't be so slow to load in. we know what the models are." Before acpmux listed
// its harnesses, every bundled catalog harness read as Not installed and none of its models was
// pickable; OpenCode's probed list was lost to its `default` placeholder on every fetch. Leo
// 2026-11-08 on the provider logo (#38095): "we can keep this as defualt for now but let's add
// toggle and make right clicking the model picker let you customize".

const harness = (id: string, installed: boolean) => ({
  id,
  name: id,
  brand: id,
  acpmuxHarness: installed ? id : null,
  installed,
  pickable: true,
  models: [{ id: `${id}-model`, name: `${id} model`, shortName: `${id} model` }],
});

describe("the model menu before acpmux lists its harnesses", () => {
  test("bundled catalog harnesses are pickable, none Not installed", async () => {
    const { composerPickerEntries } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const catalog = { harnesses: [harness("claude", false), harness("codex", false)], provisional: true };
    const before = composerPickerEntries({ catalog: [], summary: undefined } as never, catalog as never, false);
    expect(before.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", true, undefined],
      ["codex", true, undefined],
    ]);
    // Once acpmux has answered, a harness it does not run is Not installed, as before.
    const after = composerPickerEntries({ catalog: [], summary: undefined } as never, catalog as never, true);
    expect(after.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", false, true],
      ["codex", false, true],
    ]);
  });

  test("the face draws the first catalog harness before the list", async () => {
    const { composerHealthHarness } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const catalog = { harnesses: [harness("claude", false)], provisional: true };
    expect(composerHealthHarness({ catalog: [], summary: undefined } as never, catalog as never, false)).toBe("claude");
  });

  test("a harness reporting only its default placeholder keeps its cached models", async () => {
    const { HarnessCatalogCache } = await import("../src/agent-session/acpmux/catalog");
    const store = new Map<string, string>();
    const storage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
    } as unknown as Storage;
    const probed = [{ id: "opencode/gpt-6", name: "GPT-6" }];
    new HarnessCatalogCache(() => storage).merge([{ id: "opencode", name: "OpenCode", models: probed }] as never, 1);
    const merged = new HarnessCatalogCache(() => storage).merge(
      [{ id: "opencode", name: "OpenCode", models: [{ id: "default", name: "Default" }] }] as never,
      2,
    );
    expect(merged[0]!.models).toEqual(probed);
  });
});

describe("the model chip's right-click menu", () => {
  const render = async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[{ id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }], pickable: true }]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
        />,
      ),
    );
  };
  const rightClick = async () => {
    const chip = host.querySelector(".acpmux-model .acpmux-picker-button")!;
    await act(async () =>
      chip.dispatchEvent(
        new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 4, clientY: 4 }),
      ),
    );
    await settle();
  };
  const item = (label: string) =>
    [...dom.window.document.querySelectorAll<HTMLElement>("[role^='menuitem']")].find(
      (row) => row.querySelector(".ui-menu-label")?.textContent?.trim() === label,
    );

  test("Show Provider Logo is on by default and turns the logo off and on", async () => {
    const { resetModelChipLookForTests } = await import("../src/agent-session/acpmux/modelChipLook");
    resetModelChipLookForTests();
    await render();
    const chip = () => host.querySelector(".acpmux-model")!;
    expect(chip().getAttribute("data-chip-logo")).toBeNull();
    expect(host.querySelector(".acpmux-model .agent-mark")).not.toBeNull();
    await rightClick();
    const logo = item("Show Provider Logo")!;
    expect(logo).not.toBeUndefined();
    expect(logo.getAttribute("aria-checked")).toBe("true");
    expect(item("Show Effort")).not.toBeUndefined();
    expect(item("More models")).not.toBeUndefined();
    await act(async () => logo.click());
    await settle();
    expect(chip().getAttribute("data-chip-logo")).toBe("off");
    expect(JSON.parse(dom.window.localStorage.getItem("cmux.acpmux.modelChipLook")!)).toEqual({
      providerLogo: false,
      effort: true,
    });
    await rightClick();
    expect(item("Show Provider Logo")!.getAttribute("aria-checked")).toBe("false");
    await act(async () => item("Show Provider Logo")!.click());
    await settle();
    expect(chip().getAttribute("data-chip-logo")).toBeNull();
  });
});

// Review F1 on 2b76c61e: with no chip on the page the look stayed cached while storage events went
// unheard, so another page's change was lost on remount and a toggle wrote back a stale other flag.
describe("the model chip look across pages", () => {
  const KEY = "cmux.acpmux.modelChipLook";

  test("a change made while no chip listens shows when a chip mounts again", async () => {
    const look = await import("../src/agent-session/acpmux/modelChipLook");
    look.resetModelChipLookForTests();
    const { createRoot } = await import("react-dom/client");
    const seen: boolean[] = [];
    function Probe() {
      seen.push(look.useModelChipLook().providerLogo);
      return null;
    }
    root = createRoot(host);
    await act(async () => root!.render(<Probe />));
    expect(seen.at(-1)).toBe(true);
    act(() => root!.unmount());
    // Another page turns the logo off while this page draws no chip.
    dom.window.localStorage.setItem(KEY, JSON.stringify({ providerLogo: false, effort: true }));
    root = createRoot(host);
    await act(async () => root!.render(<Probe />));
    await settle();
    expect(seen.at(-1)).toBe(false);
  });

  test("a toggle keeps the other flag another page set", async () => {
    const look = await import("../src/agent-session/acpmux/modelChipLook");
    look.resetModelChipLookForTests();
    const { createRoot } = await import("react-dom/client");
    function Probe() {
      look.useModelChipLook();
      return null;
    }
    root = createRoot(host);
    await act(async () => root!.render(<Probe />));
    act(() => root!.unmount());
    root = undefined;
    dom.window.localStorage.setItem(KEY, JSON.stringify({ providerLogo: true, effort: false }));
    look.setModelChipLook({ providerLogo: false });
    expect(JSON.parse(dom.window.localStorage.getItem(KEY)!)).toEqual({ providerLogo: false, effort: false });
  });
});

// Coordinator ask on #39080: the daemon is down (acpmux never answered with its harnesses) and a
// started Claude chat's model menu still lists Claude Code's bundled models. A regression guard for
// #39080's fix: red on feat-cmux-next d48c603d (the menu drew no models), green on e09d48cb.
describe("the model menu with the daemon down", () => {
  const mount = async (harnessesListed: boolean) => {
    const { createRoot } = await import("react-dom/client");
    const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
    const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
    const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
    const { BUNDLED_MODEL_CATALOG, buildPickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogData");
    const { user } = await import("../src/gallery/fixtures/acpmux");
    const snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      sessionId: "down",
      rows: [user("Add retries", 1)],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: [],
      summary: { sessionId: "down", harness: "claude", model: "claude-opus-5-5", turnCount: 3 },
    } as unknown as import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
    const pickerCatalog = buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: [], provisional: true });
    const accounts = { list: async () => ({ accounts: [] }), set: async () => undefined };
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <QueryClientProvider client={new QueryClient()}>
          <ChatAccountsContext.Provider value={accounts}>
            <ComposerPickers
              snapshot={snapshot}
              pickerCatalog={pickerCatalog}
              harnessesListed={harnessesListed}
              onModel={() => undefined}
              onMode={() => undefined}
              onEffort={() => undefined}
              onHarness={() => undefined}
              showPlan={false}
            />
          </ChatAccountsContext.Provider>
        </QueryClientProvider>,
      ),
    );
    await settle();

    await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
    await settle();
  };
  // A started chat that cannot fork opens the list menu (QuickModelMenu); one with a rail, the columns.
  const menu = () =>
    dom.window.document.querySelector<HTMLElement>(".acpmux-cols, .acpmux-quick-menu:not(.acpmux-quick-submenu)");
  const modelNames = () =>
    [...(menu()?.querySelectorAll<HTMLElement>('[role="menuitemradio"], [role="listbox"] [role="option"]') ?? [])].map(
      (row) => row.querySelector(".acpmux-quick-label, .acpmux-cols-name")?.textContent?.trim() ?? "",
    );
  const updatingNote = () => menu()?.querySelector<HTMLElement>(".acpmux-models-updating") ?? null;

  test("a started Claude chat lists Claude Code's models", async () => {
    await mount(false);
    expect(menu()).not.toBeNull();
    expect(modelNames()).toContain("Opus 5.5");
  });

  // Coordinator ask: while acpmux has not listed its harnesses (or the fetch failed), the menu says
  // quietly that models are updating, beside the bundled models, never in place of them.
  test("says quietly that models are updating, beside the models, until acpmux answers", async () => {
    await mount(false);
    expect(modelNames()).toContain("Opus 5.5");
    expect(updatingNote()?.textContent?.trim()).toBe("Refreshing models");
    act(() => root!.unmount());
    root = undefined;
    for (const popup of dom.window.document.querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
    await mount(true);
    expect(updatingNote()).toBeNull();
  });
});
