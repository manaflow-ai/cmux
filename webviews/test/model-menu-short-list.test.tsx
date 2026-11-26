// Leo 2026-10-21 on the nightly: "why are there so many models!? it should be truncating and then
// showing more models" and "this should just show the effort too right? and then the effort tells
// you what you're already currently on?". His started Claude chat's model menu listed nine numbered
// rows, Opus 5.5 twice: Claude Code's `opus` alias (which it names "Opus 5.5") and the pinned
// release the chat runs, `claude-opus-5-5`. The menu lists each model once.
// A started chat's model button opens the shared columns menu, as a New Tab's does (cmux#55750):
// its Reasoning column checks the level the chat is on; its Fast switch says whether it is on.
// The real composer, catalog and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  await teardownDom(saved, { window: dom.window, scope });
});

/// Claude Code's model list as Leo's chat reported it: its aliases named as the releases they run,
/// its 1M and plan modes, and Fable 5.1 pinned. The chat runs the pinned release claude-opus-5-5,
/// which the list does not name; Claude Code's `opus` is the same model.
const CLAUDE_CODE_MODELS = [
  { id: "default", name: "Default (recommended)" },
  { id: "opus", name: "Opus 5.5" },
  { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
  { id: "sonnet", name: "Sonnet 5.5" },
  { id: "haiku", name: "Haiku 5.5" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet[1m]", name: "Sonnet · 1M context" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
];

type Mount = {
  /** acpmux's id for the chat's harness: the catalog's `claude`, or a profile the catalog does not map. */
  harness: string;
  family: string;
  model?: string;
  effort?: string;
  fast?: boolean;
  /** What the profile declares for a model it lists (acpmux's `efforts`, `fast`), by id. */
  declared?: Record<string, { efforts?: string[]; fast?: boolean }>;
};

async function mount({
  harness,
  family,
  model = "claude-opus-5-5",
  effort = "medium",
  fast = false,
  declared = {},
}: Mount) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const sent: { id: string; value: string }[] = [];
  function Host() {
    const [state, setState] = useState({ model, effort, fast: "off" });
    const configOptions = [
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: state.model,
        options: CLAUDE_CODE_MODELS.map((choice) => ({ value: choice.id, name: choice.name })),
      },
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: state.effort,
        options: ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value, name: value })),
      },
      ...(fast
        ? [
            {
              id: "fast-mode",
              name: "Fast Mode",
              currentValue: state.fast,
              options: [
                { value: "off", name: "Off" },
                { value: "on", name: "On" },
              ],
            },
          ]
        : []),
    ];
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
          id: harness,
          name: "Claude Code",
          family,
          models: CLAUDE_CODE_MODELS.map((choice) => ({ ...choice, ...declared[choice.id] })),
        },
      ],
      summary: { sessionId: "s1", harness, family, model: state.model, turnCount: 12, configOptions },
    } as unknown as Snapshot;
    const picker = usePickerCatalog(
      snapshot.catalog,
      { harness, model: state.model, configOptions },
      snapshot.sessions,
    );
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={(next) => {
          sent.push({ id: "model", value: next });
          setState((current) => ({ ...current, model: next }));
        }}
        onMode={() => undefined}
        onEffort={(id, value) => {
          sent.push({ id, value });
          setState((current) => (id === "fast-mode" ? { ...current, fast: value } : { ...current, effort: value }));
        }}
        showPlan={false}
        harnessesListed
      />
    );
  }
  root = createRoot(host);
  const client = new QueryClient();
  await act(async () =>
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    ),
  );
  return { sent };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chipButton = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const menus = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
const menu = () => menus()[0];
const label = (row: Element) => row.querySelector(".acpmux-menu-label")?.textContent?.trim() ?? "";
/// The model rows the menu itself shows (not its submenus').
const modelRows = () => [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]')];

// The model button's menu: the shared columns menu (QuickModelColumns), with its harness rail, the
// shown harness's models and the shown model's Reasoning column and Fast switch.
const cols = () => doc().querySelector<HTMLElement>(".acpmux-cols");
const colName = (row: Element) => row.querySelector(".acpmux-cols-name")?.textContent?.trim() ?? "";
const colRows = () => [...(cols()?.querySelectorAll<HTMLElement>('[role="listbox"] [role="option"]') ?? [])];
const colChecked = () => colRows().filter((row) => row.getAttribute("aria-selected") === "true");
const railTabs = () => [...(cols()?.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]') ?? [])];
const levels = () => [...(cols()?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]') ?? [])];
const checkedLevel = () => levels().find((row) => row.getAttribute("aria-checked") === "true");
const fastSwitch = () => cols()?.querySelector<HTMLElement>('.acpmux-cols-tune [role="switch"]') ?? null;
/// A key in the menu's search field, which has the keyboard while the menu is open.
async function press(key: string) {
  const field = cols()!.querySelector<HTMLInputElement>(".acpmux-cols-search input[type=search]")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true }));
  });
  await settle();
}

async function open() {
  await act(async () => chipButton().click());
  await settle();
}

test("Fable uses its reported 1M option under one plain model name", async () => {
  const { sent } = await mount({ harness: "claude", family: "claude" });
  await open();
  const fable = colRows().filter((row) => colName(row).includes("Fable 5.1"));
  expect(fable.map(colName)).toEqual(["Fable 5.1"]);
  await act(async () => fable[0]!.click());
  await settle();
  expect(sent).toContainEqual({ id: "model", value: "claude-fable-5-1[1m]" });
});

for (const model of ["claude-fable-5-1", "claude-fable-5-1[1m]"])
  test(`a chat already on ${model} keeps its checked Fable row without changing the session`, async () => {
    const { sent } = await mount({ harness: "claude", family: "claude", model });
    await open();
    const fable = colRows().filter((row) => colName(row).includes("Fable 5.1"));
    expect(fable.map(colName)).toEqual(["Fable 5.1"]);
    expect(fable[0]!.getAttribute("aria-selected")).toBe("true");
    expect(sent).toEqual([]);
  });

// The button names whose sign-in fixes the chat (sessionAuth.ts authLoginText; 88fae780, user Nov 19:
// "hard to tell if cmux is signed out or the model provider is signed out"): the agent's own sign-in
// when acpmux names the agent, else Sign in again. This test kept the old word for both.
for (const [state, harness, word] of [
  ["expired", "claude", "Sign in to Claude Code"],
  ["signedOut", "claude", "Sign in to Claude Code"],
  ["expired", null, "Sign in again"],
  ["signedOut", null, "Sign in again"],
] as const) {
  test(`full picker offers ${word} for ${state} auth (agent ${harness ?? "unnamed"}) before send`, async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    let logins = 0;
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[{ id: "claude", name: "Claude Code", models: CLAUDE_CODE_MODELS }]}
          harness="claude"
          model="claude-opus-5-5"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={() => undefined}
          onEffort={() => undefined}
          sessionAuth={{
            state,
            source: "turn",
            evidenceAt: 1,
            harness: harness ?? undefined,
            host: null,
            login: { kind: "terminal", command: "claude auth login" },
          }}
          onSessionLogin={() => logins++}
        />,
      ),
    );
    await open();
    const login = doc().querySelector<HTMLButtonElement>(".acpmux-mp-auth-action");
    expect(login?.textContent).toBe(word);
    await act(async () => login!.click());
    expect(logins).toBe(1);
  });
}

for (const [title, harness, family] of [
  ["the catalog's Claude Code", "claude", "claude"],
  ["a Claude profile the catalog does not map", "claude-sr2", "claude-sr2"],
] as const)
  describe(`Leo's started chat on ${title}`, () => {
    // A started chat's menu is the shared columns menu, rail and all (cmux#55750); the running
    // harness's tab lists every model of its harness in one column, each once.
    test("shows the shared menu on its harness's tab, each model once", async () => {
      await mount({ harness, family });
      await open();
      expect(cols(), "the columns menu").not.toBeNull();
      expect(railTabs().length, "the harness rail").toBeGreaterThan(0);
      expect(railTabs().filter((tab) => tab.getAttribute("aria-selected") === "true")).toHaveLength(1);
      const shown = colRows().map(colName);
      expect(new Set(shown).size, shown.join(", ")).toBe(shown.length);
      expect(
        shown.filter((name) => name === "Opus 5.5"),
        shown.join(", "),
      ).toEqual(["Opus 5.5"]);
      expect(colChecked().map(colName)).toEqual(["Opus 5.5"]);
    });

    test("number keys pick only the shown rows", async () => {
      const { sent } = await mount({ harness, family });
      await open();
      const rows = colRows();
      // A digit past the shown rows picks nothing and leaves the menu open.
      if (rows.length < 9) {
        await press(String(rows.length + 1));
        expect(sent).toEqual([]);
        expect(cols()).not.toBeNull();
      }
      // A digit picks the shown row at that place: here the first that is not the running one.
      const index = rows.slice(0, 9).findIndex((row) => row.getAttribute("aria-selected") !== "true");
      expect(index).toBeGreaterThanOrEqual(0);
      const id = rows[index]!.dataset.flip!.split("\u0000")[1];
      await press(String(index + 1));
      expect(sent).toEqual([{ id: "model", value: id! }]);
    });
  });

for (const harnessFixed of [false, true]) {
  test(`relevant models are not truncated in a ${harnessFixed ? "started chat" : "harness rail"}`, async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const choices = Array.from({ length: 8 }, (_, index) => ({ id: `choice-${index}`, name: `Choice ${index}` }));
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[
            {
              id: "test-harness",
              name: "Test harness",
              models: choices,
              top: ["choice-0", "choice-1", "choice-2", "choice-3", "choice-4", "choice-5"],
            },
          ]}
          harness="test-harness"
          harnessFixed={harnessFixed}
          model="choice-7"
          label="Choice 7"
          efforts={[]}
          recents={[{ harness: "test-harness", model: "choice-6" }]}
          onLand={() => undefined}
          onEffort={() => undefined}
          quick={{}}
        />,
      ),
    );
    await open();
    const top = choices.slice(0, 6).map((choice) => choice.name);
    if (!harnessFixed) {
      // A rail's menu is the columns menu: the top models, then the harness's other models in the
      // same column, with no caption between them (#41212).
      const list = [...doc().querySelector('.acpmux-cols [role="listbox"]')!.children];
      expect(list.some((item) => item.textContent === "Legacy models")).toBe(false);
      const names = list
        .filter((item) => item.getAttribute("role") === "option")
        .map((item) => item.querySelector(".acpmux-cols-name")?.textContent ?? "");
      expect(names.slice(0, top.length)).toEqual(top);
      expect(names.slice(top.length).sort()).toEqual(["Choice 6", "Choice 7"]);
      return;
    }
    expect(modelRows().map(label)).toEqual(top);
    // A started chat's More models opens the full picker.
    expect(menu()!.textContent).toContain("More models");
    expect(modelRows().map(label)).not.toContain("Choice 6");
    expect(modelRows().map(label)).not.toContain("Choice 7");
  });
}

test("the current model's Reasoning column checks the level the chat is on", async () => {
  await mount({ harness: "claude", family: "claude", effort: "high" });
  await open();
  expect(colChecked().map(colName)).toEqual(["Opus 5.5"]);
  expect(checkedLevel() && colName(checkedLevel()!), levels().map(colName).join(", ")).toBe("High");
});

test("the Fast mode switch shows whether it is on", async () => {
  const { sent } = await mount({ harness: "claude", family: "claude", fast: true });
  await open();
  expect(fastSwitch(), "the Fast switch").not.toBeNull();
  expect(fastSwitch()!.getAttribute("aria-checked")).toBe("false");
  expect(colName(fastSwitch()!)).toBe("Fast");
  await act(async () => fastSwitch()!.click());
  await settle();
  expect(sent).toEqual([{ id: "fast-mode", value: "on" }]);
  if (!cols()) await open();
  expect(fastSwitch()!.getAttribute("aria-checked")).toBe("true");
});

// Codex review at 87da5d12: a profile that declares no levels for `opus` (efforts: []) left the chat
// on claude-opus-5-5, the same model, with an Effort row offering every level the session lists, so
// a pick sent a level the profile said the model does not take.
test("a model its profile declares with no effort levels shows no levels, though the session lists levels", async () => {
  const { sent } = await mount({ harness: "claude-sr2", family: "claude-sr2", declared: { opus: { efforts: [] } } });
  await open();
  expect(levels().map(colName), "no level to pick").toEqual([]);
  expect(colChecked().map(colName), "the running model is still the checked row").toEqual(["Opus 5.5"]);
  expect(sent).toEqual([]);
});

// A profile may declare one alias without effort levels while another model still supports them.
// The no-effort declaration must be scoped to the running model, not disable the whole profile.
test("a sibling no-effort model does not hide Effort for the running model", async () => {
  await mount({
    harness: "claude-sr2",
    family: "claude-sr2",
    model: "claude-fable-5-1",
    effort: "high",
    declared: { opus: { efforts: [] } },
  });
  await open();
  expect(colChecked().map(colName)).toEqual(["Fable 5.1"]);
  expect(checkedLevel() && colName(checkedLevel()!), levels().map(colName).join(", ")).toBe("High");
});
