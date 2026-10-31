// Leo 2026-10-21 on the nightly: "why are there so many models!? it should be truncating and then
// showing more models" and "this should just show the effort too right? and then the effort tells
// you what you're already currently on?". His started Claude chat's model menu listed nine numbered
// rows, Opus 5.5 twice: Claude Code's `opus` alias (which it names "Opus 5.5") and the pinned
// release the chat runs, `claude-opus-5-5`. The menu follows the harness's own list,
// else its newest models per family, each once, and keeps everything else under More models,
// which in a started chat opens the full picker.
// Inline effort segments name the level the chat is on; the Fast mode row says whether it is on.
// The real composer, catalog and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { openEffort } from "./support/effortDropdown";

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
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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
        onModel={(next) => setState((current) => ({ ...current, model: next }))}
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
/// A model row's effort levels: its side dropdown, opened.
const effortFor = (row: HTMLElement) => openEffort(row.ownerDocument, label(row));
/// The model rows the menu itself shows (not its submenus').
const modelRows = () => [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]')];
const rowText = (row: Element) => row.textContent?.replace("✓", "").trim() ?? "";

async function open() {
  await act(async () => chipButton().click());
  await settle();
}

for (const [title, harness, family] of [
  ["the catalog's Claude Code", "claude", "claude"],
  ["a Claude profile the catalog does not map", "claude-sr2", "claude-sr2"],
] as const)
  describe(`Leo's started chat on ${title}`, () => {
    test("shows the harness menu, each model once; the rest are under More models", async () => {
      await mount({ harness, family });
      await open();
      const shown = modelRows().map(label);
      expect(shown).toContain("Opus 5.5");
      expect(new Set(shown).size).toBe(shown.length);
      expect(shown, "the running model is shown").toContain("Opus 5.5");
      const checked = menu()!.querySelector('.acpmux-quick-item[role="menuitemradio"][aria-checked="true"]');
      expect(checked && label(checked)).toBe("Opus 5.5");
      // A started chat's More models opens the full picker: every model of its harness, each once.
      const moreRow = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
        label(item).startsWith("More models"),
      )!;
      await act(async () => moreRow.click());
      await settle();
      const fold = host.querySelector<HTMLButtonElement>(".acpmux-mp-older");
      if (fold && fold.getAttribute("aria-expanded") !== "true") await act(async () => fold.click());
      const every = [
        ...host.querySelectorAll<HTMLElement>('.acpmux-mp-models [role="option"][data-key^="model:"]'),
      ].map(label);
      expect(every.length, "More models retains every harness menu choice").toBeGreaterThanOrEqual(shown.length);
      for (const name of shown) expect(every, every.join(", ")).toContain(name);
      expect(
        every.filter((name) => name === "Opus 5.5"),
        every.join(", "),
      ).toEqual(["Opus 5.5"]);
      expect(new Set(every).size, every.join(", ")).toBe(every.length);
    });

    test("number keys name only the shown rows", async () => {
      await mount({ harness, family });
      await open();
      const rows = modelRows();
      // The symbols row's menu names its keys ⌘1 to ⌘9 (a bare digit picks the same row).
      const keysShown = rows.map((row) => row.querySelector(".ui-menu-shortcut")?.textContent?.replace("⌘", "") ?? "✓");
      expect(keysShown).toEqual(
        rows.map((row, index) => (row.getAttribute("aria-checked") === "true" ? "✓" : String(index + 1))),
      );
      expect(keysShown.every((key) => key === "✓" || Number(key) <= rows.length)).toBe(true);
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
    expect(modelRows().map(label)).toEqual(choices.slice(0, 6).map((choice) => choice.name));
    // A rail's other models are Legacy models in the default symbols layout; a started chat's More
    // models opens the full picker.
    expect(menu()!.textContent).toContain(harnessFixed ? "More models" : "Legacy models");
    expect(modelRows().map(label)).not.toContain("Choice 6");
    expect(modelRows().map(label)).not.toContain("Choice 7");
  });
}

test("the current model's inline effort control checks the level the chat is on", async () => {
  await mount({ harness: "claude", family: "claude", effort: "high" });
  await open();
  const model = modelRows().find((row) => label(row) === "Opus 5.5")!;
  const checked = (await effortFor(model)).find((item) => item.getAttribute("aria-checked") === "true");
  expect(checked).not.toBeNull();
  expect((checked!.querySelector(".acpmux-menu-label")?.textContent ?? "").trim()).toBe("High");
});

test("the Fast mode switch shows whether it is on", async () => {
  const { sent } = await mount({ harness: "claude", family: "claude", fast: true });
  await open();
  const fast = () => menu()!.querySelector<HTMLElement>('.acpmux-quick-fast[role="menuitemcheckbox"]')!;
  expect(fast().getAttribute("aria-checked")).toBe("false");
  expect(fast().querySelector(".acpmux-quick-fast-toggle")).not.toBeNull();
  await act(async () => fast().click());
  await settle();
  expect(sent).toEqual([{ id: "fast-mode", value: "on" }]);
  if (!menu()) await open();
  expect(fast().getAttribute("aria-checked")).toBe("true");
  expect(fast().querySelector(".acpmux-menu-label")?.textContent).toBe("Fast mode");
});

// Codex review at 87da5d12: a profile that declares no levels for `opus` (efforts: []) left the chat
// on claude-opus-5-5, the same model, with an Effort row offering every level the session lists, so
// a pick sent a level the profile said the model does not take.
test("a model its profile declares with no effort levels shows no Effort row, though the session lists levels", async () => {
  const { sent } = await mount({ harness: "claude-sr2", family: "claude-sr2", declared: { opus: { efforts: [] } } });
  await open();
  const rows = [...menu()!.querySelectorAll<HTMLElement>("[role^=menuitem]")];
  expect(
    rows.find((item) => label(item).startsWith("Effort")),
    rows.map(rowText).join(", "),
  ).toBeUndefined();
  expect(rows.map(label), "the running model is still the checked row").toContain("Opus 5.5");
  expect(menu()!.querySelector('[role="menuitemradio"][aria-checked="true"]')?.textContent).toContain("Opus 5.5");
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
  const model = modelRows().find((row) => label(row) === "Fable 5.1")!;
  const checked = (await effortFor(model)).find((item) => item.getAttribute("aria-checked") === "true");
  expect(checked).not.toBeNull();
  expect((checked!.querySelector(".acpmux-menu-label")?.textContent ?? "").trim()).toBe("High");
});
