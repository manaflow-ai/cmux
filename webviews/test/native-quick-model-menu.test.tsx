// The model menu draws through the native popup host (WebPopupHost) wherever the page has one, in
// every harness placement Settings offers (design/model-picker.md, #32036): `symbols` (the default),
// `left`, `top` and `compact`. Its rail, rows and picks are the web menu's, described over the
// native popup protocol.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "../src/ui/popupProtocol";
import type { QuickFamily, QuickMenu, QuickModel } from "../src/agent-session/acpmux/QuickModelMenu";
import type { HarnessPlacement } from "../src/ui/harnessPlacement";

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
let container: HTMLElement;

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
  container = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  container.replaceChildren();
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const model = (id: string, name: string, family: string): QuickModel => ({
  id,
  name,
  family,
  efforts: ["low", "medium", "high"],
  defaultEffort: "medium",
});

const families: QuickFamily[] = [
  { id: "claude", name: "Claude Code", mark: "claude", models: [model("opus", "Opus 5.5", "claude")], more: [] },
  { id: "codex", name: "Codex", mark: "codex", models: [model("sol", "GPT-6.1 Sol", "codex")], more: [] },
  { id: "quill", name: "Quill Agent", models: [model("quill-1", "Quill One", "quill")], more: [] },
];

async function harness(placement: HarnessPlacement | undefined, reply: unknown = { shown: true }) {
  const [{ createRoot }, { UiProvider }, { createPopupHost }, { QuickModelMenu }] = await Promise.all([
    import("react-dom/client"),
    import("../src/ui/UiProvider"),
    import("../src/ui/popupHost"),
    import("../src/agent-session/acpmux/QuickModelMenu"),
  ]);
  const shows: NativePopupModel[] = [];
  const updates: NativePopupModel[] = [];
  const listeners = new Set<(event: unknown) => void>();
  const host = createPopupHost(
    (call, params) => {
      if (call === "show") shows.push(params as unknown as NativePopupModel);
      if (call === "update") updates.push(params as unknown as NativePopupModel);
      return Promise.resolve(reply);
    },
    (listener) => {
      listeners.add(listener as (event: unknown) => void);
      return () => listeners.delete(listener as (event: unknown) => void);
    },
  );
  const picked: QuickModel[] = [];
  const closes: boolean[] = [];
  let added = 0;
  const menu: QuickMenu = {
    models: [],
    current: "opus",
    onModel: () => {},
    inlineEffort: true,
    search: { find: () => [], pick: (row) => picked.push(row) },
    families: {
      list: families,
      current: "claude",
      onPick: (row) => picked.push(row),
      onAddHarness: () => added++,
    },
    ...(placement ? { harnessPlacement: placement } : {}),
  };
  const trigger = createRef<HTMLButtonElement>();
  root = createRoot(container);
  act(() =>
    root!.render(
      <UiProvider container={container} popupHost={host}>
        <QuickModelMenu
          open
          onOpenChange={(next) => closes.push(next)}
          trigger={trigger}
          chip={{ "data-menu": "Opus 5.5", label: "Opus 5.5", title: "Opus 5.5" }}
          menu={menu}
          onMore={() => {}}
        >
          Opus 5.5
        </QuickModelMenu>
      </UiProvider>,
    ),
  );
  const latest = () => updates.at(-1) ?? shows.at(-1)!;
  const send = (event: Omit<NativePopupEvent, "popupId" | "revision">) => {
    const current = latest();
    act(() => listeners.forEach((listener) => listener({ ...event, popupId: current.id, revision: current.revision })));
  };
  return { latest, send, picked, closes, added: () => added, container, shows };
}

const rail = (popup: NativePopupModel) => popup.rail ?? [];

test("a host that answers a show with no native popup leaves the open menu to the page", async () => {
  // The gallery's stand-in bridge answers every call it does not know with null.
  const h = await harness(undefined, null);
  expect(h.shows).toHaveLength(1);
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  expect(h.closes).toEqual([]);
  expect(document.querySelector(".acpmux-quick-menu")).not.toBeNull();
});

const byLabel = (rows: NativePopupRow[], label: string) => rows.find((row) => row.label === label)!;

test("with a native host the menu draws natively, its chip a plain button and no web popup", async () => {
  const h = await harness(undefined);
  expect(h.latest()).toBeDefined();
  expect(h.container.querySelector(".acpmux-quick-menu")).toBeNull();
  expect(h.container.querySelector("button.acpmux-picker-button")?.getAttribute("aria-expanded")).toBe("true");
});

test("the symbols row is the default placement: marks only, a monogram for a harness with none", async () => {
  const h = await harness(undefined);
  const popup = h.latest();
  expect(popup.railPlacement).toBe("symbols");
  expect(popup.railWidth).toBeUndefined();
  expect(rail(popup).map((row) => row.label)).toEqual(["Claude Code", "Codex", "Quill Agent", "Add harness…"]);
  expect(byLabel(rail(popup), "Claude Code").mark).toBe("claude");
  expect(byLabel(rail(popup), "Claude Code").checked).toBe(true);
  expect(byLabel(rail(popup), "Quill Agent").monogram).toBe("Q");
  expect(byLabel(rail(popup), "Add harness…").icon).toBe("action.add");
  // The symbols layout keys its rows ⌘N; the running row is checked instead.
  const rows = popup.rows.filter((row) => row.kind === "action");
  expect(rows[0]?.label).toBe("Opus 5.5");
  expect(rows[0]?.checked).toBe(true);
});

for (const placement of ["left", "top", "compact"] as const)
  test(`the ${placement} placement keeps its own layout natively`, async () => {
    const h = await harness(placement);
    const popup = h.latest();
    expect(popup.railPlacement).toBe(placement);
    // Names show on these tabs, so a harness with no symbol needs no monogram.
    expect(byLabel(rail(popup), "Quill Agent").monogram).toBeUndefined();
    if (placement === "top") expect(popup.railWidth).toBeUndefined();
    else {
      expect(popup.railWidth).toBeGreaterThanOrEqual(40);
      expect(popup.railWidth!).toBeLessThanOrEqual(popup.width / 2);
    }
    if (placement === "compact") expect(popup.railWidth).toBe(76);
  });

test("a model row's effort is a side dropdown: the model, then its levels beside it", async () => {
  const h = await harness(undefined);
  h.send({ type: "pick", id: byLabel(rail(h.latest()), "Codex").id });
  const row = byLabel(h.latest().rows, "GPT-6.1 Sol");
  expect(row.children?.map((level) => level.label)).toEqual(["Low", "Medium", "High"]);
  expect(row.sideLabel).toBeDefined();
  h.send({ type: "pick", id: row.children![2]!.id });
  expect(h.picked.map((picked) => [picked.id, picked.effort])).toEqual([["sol", "high"]]);
});

test("a rail tab switches the list, and Left and Right step the rail through Add harness", async () => {
  const h = await harness("symbols");
  h.send({ type: "pick", id: byLabel(rail(h.latest()), "Codex").id });
  expect(byLabel(rail(h.latest()), "Codex").checked).toBe(true);
  expect(h.latest().rows.some((row) => row.label === "GPT-6.1 Sol")).toBe(true);
  h.send({ type: "navigate", value: "next" });
  expect(byLabel(rail(h.latest()), "Quill Agent").checked).toBe(true);
  h.send({ type: "navigate", value: "next" });
  expect(h.latest().highlighted).toBe(byLabel(rail(h.latest()), "Add harness…").id);
  h.send({ type: "navigate", value: "next" });
  expect(byLabel(rail(h.latest()), "Claude Code").checked).toBe(true);
  h.send({ type: "pick", id: byLabel(rail(h.latest()), "Add harness…").id });
  expect(h.added()).toBe(1);
});

test("picking a model from another tab lands it", async () => {
  const h = await harness("left");
  h.send({ type: "pick", id: byLabel(rail(h.latest()), "Codex").id });
  h.send({ type: "pick", id: byLabel(h.latest().rows, "GPT-6.1 Sol").id });
  expect(h.picked.map((picked) => picked.id)).toEqual(["sol"]);
  expect(h.closes).toContain(false);
});
