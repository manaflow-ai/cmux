// l10n-allow-file: test fixtures.
// A new chat's composer draws its final chips on its first frame (Leo 2026-10-13: grey skeleton
// pills where effort and access go, then the chips, while the session started). The effort this
// harness's chats last showed and the start mode acpmux last answered (`_acpmux/start_mode`,
// startMode.ts) paint at once, and the session's report keeps the same chips in the same order
// with the same labels. The effort is the model button's detail ("Opus 5.5  High"; Leo 2026-10-20:
// one model button, no separate effort chip), the access chip follows it.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
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

// Another test file in the same bun process can leave a start-mode source or kept answers behind
// (classic-new-tab-trust): every test here starts with neither.
beforeEach(async () => {
  const { setStartModeSource, resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterEach(async () => {
  const { resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;

function reported(sessionId: string): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "default",
    turnCount: 0,
    configOptions: [
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "high",
        options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
      },
    ],
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "acceptEdits", name: "Edit automatically" },
      ],
    },
  };
}

/// Renders the composer's chips for `summary` (undefined: a new chat whose session has not reported).
async function render(summary: Summary, emptyCatalog = false) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: emptyCatalog ? [] : catalog,
    summary: summary ?? { sessionId: "", harness: "claude", turnCount: 0 },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

/// The model button's effort and the access chip, in order, as kind and label.
const chips = () =>
  [
    ...host.querySelectorAll<HTMLElement>(".acpmux-model .acpmux-model-detail:not(.acpmux-fit-label), .acpmux-mode"),
  ].map((chip) =>
    chip.classList.contains("acpmux-mode")
      ? { kind: "mode", label: (chip.querySelector(".acpmux-picker-button")?.textContent ?? "").trim() }
      : { kind: "effort", label: (chip.textContent ?? "").trim() },
  );

test("a new chat paints its last effort and its kept start mode on the first frame, and its session keeps them in place", async () => {
  // An earlier chat on this harness reported its chips.
  await render(reported("earlier"));
  const earlier = chips();
  expect(earlier.map((chip) => chip.kind)).toEqual(["effort", "mode"]);
  expect(earlier.every((chip) => chip.label.length > 0)).toBe(true);
  expect(earlier[0]!.label).toBe("High");
  // One model control: no effort chip beside it.
  expect(host.querySelector(".acpmux-effort")).toBeNull();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();

  // acpmux answered, in an earlier ask for another folder, that a new chat on this harness starts
  // in that chat's mode; a folder it has not answered for yet names that answer until its own
  // replaces it (Lucas 2026-10-24: never a bare "Mode" on this Mac).
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  // Bypass permissions: named the same in every menu, so a harness profile another test file left
  // in the shared HarnessProfiles (which names `default` "Manual") cannot rename it.
  rememberStartMode("claude", "/home/dev/other", { modeId: "bypassPermissions", name: "Bypass permissions" });

  // A new chat, before its session reports: no grey bars, the same chips in the same order.
  await render(undefined);
  expect(host.querySelector(".acpmux-chip-skeleton, .acpmux-chip-skeleton-bar")).toBeNull();
  const first = chips();
  expect(first).toEqual([earlier[0]!, { kind: "mode", label: "Bypass permissions" }]);

  // Its session reports the same choices: the chips settle where they were.
  await render(reported("new"));
  expect(chips()).toEqual(earlier);
});

test("with no remembered chips a new chat draws no placeholder pills and no Reasoning word, and names the highest mode", async () => {
  await render(undefined);
  expect(host.querySelector(".acpmux-chip-skeleton, .acpmux-chip-skeleton-bar")).toBeNull();
  // acpmux never answered for this harness here: the harness's highest level (Leo 2026-10-23: "if you
  // don't know what to switch to, typically just switch to the highest permission level").
  expect(chips()).toEqual([{ kind: "mode", label: "Bypass permissions" }]);
  expect(host.textContent).not.toContain("Reasoning");
});

test("a new chat shows the bundled model picker before the host catalog arrives", async () => {
  await render(undefined, true);
  expect(host.querySelector(".acpmux-model-name")?.textContent?.trim()).toBeTruthy();
});
