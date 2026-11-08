// Leo 2026-10-22, on a claude-sr2 chat's model button and its Effort submenu: "this should just
// show the effort too right? and then the effort tells you what you're already currrently on?"
// The button read "Opus 5.5" alone and no level was checked: the chat ran the agent's default
// effort, and the profile's own model row names no default level, so it resolved to nothing. The
// real composer, catalog and menu, in JSDOM.
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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// A chat on Claude Code's profile `claude-sr2` (a second account's harness id the model catalog
/// does not map): acpmux lists its models by name only, as its probe reports them.
const PROFILE_MODELS = [
  { id: "default", name: "Default (Claude Code's choice)" },
  { id: "opus", name: "Opus" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
];

type Chat = {
  harness: string;
  family: string;
  effort: string;
  /** The model the session reports (`summary.model`); Opus 5.5's release id when unset. */
  model?: string;
  /** What the session's model option says it runs; `model` when unset. */
  running?: string;
  /** The profile's model rows as acpmux lists them; PROFILE_MODELS when unset. */
  rows?: { id: string; name: string; release?: string }[];
  /** The catalogued `claude` profile also reports Claude Code's `opus` as "Opus 5.5": the catalog
   *  join folds it into Opus 5.5's row, whose own level is Medium. */
  claudeOpus?: boolean;
};

async function mount(chat: Chat) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const acpmux = [
    ...BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: [
        ...(chat.claudeOpus && harness.id === "claude" ? [{ id: "opus", name: "Opus 5.5" }] : []),
        ...harness.models.map((model) => ({ id: model.id, name: model.name })),
      ],
    })),
    { id: "claude-sr2", name: "claude-sr2", family: "claude-sr2", models: chat.rows ?? PROFILE_MODELS },
  ] as Snapshot["catalog"];
  const sent: string[] = [];
  function Host() {
    const [effort, setEffort] = useState(chat.effort);
    const snapshot = {
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
        sessionId: "s1",
        harness: chat.harness,
        family: chat.family,
        model: chat.model ?? "claude-opus-5-5",
        turnCount: 1,
        configOptions: [
          {
            id: "model",
            name: "Model",
            category: "model",
            currentValue: chat.running ?? chat.model ?? "claude-opus-5-5",
            options: PROFILE_MODELS.map((model) => ({ value: model.id, name: model.name })),
          },
          // acpmux's Claude Code Reasoning option: "default" leaves the model's own level.
          {
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: effort,
            options: [
              { value: "default", name: "Default" },
              { value: "low", name: "Low" },
              { value: "medium", name: "Medium" },
              { value: "high", name: "High" },
              { value: "xhigh", name: "Extra High" },
              { value: "max", name: "Max" },
            ],
          },
        ],
      },
    } as Snapshot;
    const picker = usePickerCatalog(snapshot.catalog, { harness: chat.harness }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={(_id, value) => {
          sent.push(value);
          setEffort(value);
        }}
        showPlan={false}
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
const modelButton = () => host.querySelector<HTMLButtonElement>(".acpmux-model .acpmux-picker-button")!;
const menus = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
const effortRow = () =>
  [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Effort"),
  );

async function openEffort() {
  await act(async () => modelButton().click());
  await settle();
  const opened = menus()[0]!;
  const current = opened.querySelector<HTMLElement>('.acpmux-quick-item[role="menuitemradio"][aria-checked="true"]');
  // The running model's effort item opens its levels as a side dropdown beside the row.
  const trigger = (
    current?.closest(".acpmux-quick-model-effort") ?? opened.querySelector(".acpmux-quick-model-effort[data-running]")
  )?.querySelector<HTMLElement>(".acpmux-quick-effort-trigger");
  if (trigger) {
    await act(async () => trigger.click());
    await settle();
    return doc().querySelector<HTMLElement>(".acpmux-quick-effort-menu")!;
  }
  const row = effortRow();
  expect(row).toBeDefined();
  await act(async () => row!.click());
  await settle();
  return menus().at(-1)!;
}

const checked = (popup: HTMLElement) =>
  [...popup.querySelectorAll<HTMLElement>('[role="menuitemradio"][aria-checked="true"]')].map(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent,
  );
/// The level the menu names for the running model: its effort item's own text (the side dropdown's
/// trigger), else the Effort row's value.
const shownEffort = (popup: HTMLElement) => {
  if (popup.matches(".acpmux-quick-effort-menu")) {
    const now = doc().querySelector<HTMLElement>(
      ".acpmux-quick-effort-trigger[data-popup-open] .acpmux-quick-effort-now",
    );
    const text = [...(now?.childNodes ?? [])]
      .filter((node) => !(node instanceof dom.window.HTMLElement && node.classList.contains("sr-only")))
      .map((node) => node.textContent)
      .join("")
      .trim();
    return text || undefined;
  }
  return popup.querySelector<HTMLElement>(".acpmux-quick-value")?.textContent;
};

// The profile's probed Opus 5.5 row names no default level; the catalog's Opus 5.5 does (Medium).
// Inline effort controls use the catalogued level when the model is resolved.
test("a profile chat on the agent's default effort names the model's own level on the button", async () => {
  await mount({ harness: "claude-sr2", family: "claude-sr2", effort: "default" });
  const face = modelButton().textContent ?? "";
  expect(face).toContain("Opus 5.5");
  expect(face).toContain("Medium");
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
});

test("its inline effort control names that level and checks it", async () => {
  await mount({ harness: "claude-sr2", family: "claude-sr2", effort: "default" });
  const levels = await openEffort();
  expect(shownEffort(levels)).toBe("Medium");
  expect(checked(levels)).toEqual(["Medium"]);
  // The check is the menus' own glyph, not a dot or a badge.
  const medium = levels.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]')!;
  expect(medium.querySelector(".ui-menu-check")).not.toBeNull();
});

test("a level the chat picked wins over the model's default", async () => {
  const { sent } = await mount({ harness: "claude-sr2", family: "claude-sr2", effort: "default" });
  const levels = await openEffort();
  const high = [...levels.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent?.replace("✓", "").trim() === "High",
  )!;
  await act(async () => high.click());
  await settle();
  expect(sent).toEqual(["high"]);
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("High");
  const again = await openEffort();
  expect(checked(again)).toEqual(["High"]);
});

test("a catalogued Claude chat on its default effort still names Medium", async () => {
  await mount({ harness: "claude", family: "claude", effort: "default" });
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
  const levels = await openEffort();
  expect(checked(levels)).toEqual(["Medium"]);
});

// Codex review of #24376: an unmapped profile can run Claude Code's alias `opus`. Its row names no
// level and no catalog row has the id `opus`, so the button named no effort and nothing was
// checked. The alias is looked up as the release it runs.
test("a profile chat on the alias opus, which runs Opus 5.5, names Medium and checks it", async () => {
  await mount({
    harness: "claude-sr2",
    family: "claude-sr2",
    effort: "default",
    model: "opus",
    running: "claude-opus-5-5",
  });
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
  const levels = await openEffort();
  expect(shownEffort(levels)).toBe("Medium");
  expect(checked(levels)).toEqual(["Medium"]);
});

test("an alias row that names its release resolves the same way", async () => {
  await mount({
    harness: "claude-sr2",
    family: "claude-sr2",
    effort: "default",
    model: "opus",
    rows: [
      { id: "default", name: "Default (Claude Code's choice)" },
      { id: "opus", name: "Opus", release: "claude-opus-5-5" },
      { id: "claude-fable-5-1", name: "Fable 5.1" },
    ],
  });
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
  const levels = await openEffort();
  expect(checked(levels)).toEqual(["Medium"]);
});

test("an alias whose release is unknown still names no level, never a guess", async () => {
  await mount({ harness: "claude-sr2", family: "claude-sr2", effort: "default", model: "opus" });
  expect(host.querySelector(".acpmux-model-detail")).toBeNull();
});

// Codex review of #24376 at 03c55364: another profile's alias is not this chat's. The catalogued
// `claude` profile reports `opus` as Opus 5.5, so the join folds `opus` into a row whose level is
// Medium. A claude-sr2 chat on `opus` that names no release, or one the catalog does not know, runs
// a model nobody here has resolved: its button names no level and its effort control checks none.
for (const running of ["opus", "claude-opus-9-9"]) {
  test(`an alias another profile folded does not lend its level (model option ${running})`, async () => {
    await mount({
      harness: "claude-sr2",
      family: "claude-sr2",
      effort: "default",
      model: "opus",
      running,
      claudeOpus: true,
    });
    expect(host.querySelector(".acpmux-model-detail")?.textContent).toBeUndefined();
    const levels = await openEffort();
    expect(shownEffort(levels)).toBeUndefined();
    expect(checked(levels)).toEqual([]);
  });
}

test("with that fold in place, the chat's own resolved release still names its level", async () => {
  await mount({
    harness: "claude-sr2",
    family: "claude-sr2",
    effort: "default",
    model: "opus",
    running: "claude-opus-5-5",
    claudeOpus: true,
  });
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
  const levels = await openEffort();
  expect(checked(levels)).toEqual(["Medium"]);
});

test("with that fold in place, a profile chat on the release itself names its level", async () => {
  await mount({ harness: "claude-sr2", family: "claude-sr2", effort: "default", claudeOpus: true });
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
});
