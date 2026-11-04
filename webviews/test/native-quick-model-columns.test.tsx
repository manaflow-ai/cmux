// The model menu's columns (#32980: harness rail, models, then the shown model's effort and Fast,
// with the account avatar in the search row) draw through the native popup host (WebPopupHost)
// wherever the page has one (design/model-picker.md). The columns, checks and picks are the web
// columns', described over the native popup protocol's `columns` layout; a menu with no rail keeps
// QuickModelMenu's native list.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "../src/ui/popupProtocol";
import type { QuickFamily, QuickMenu, QuickModel } from "../src/agent-session/acpmux/QuickModelMenu";

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

const model = (id: string, name: string, family: string, extra: Partial<QuickModel> = {}): QuickModel => ({
  id,
  name,
  family,
  efforts: ["low", "medium", "high"],
  defaultEffort: "medium",
  ...extra,
});

const families: QuickFamily[] = [
  {
    id: "claude",
    name: "Claude Code",
    mark: "claude",
    models: [model("opus", "Opus 5.5", "claude"), model("sonnet", "Sonnet 5.5", "claude")],
    more: [],
  },
  { id: "codex", name: "Codex", mark: "codex", models: [model("sol", "GPT-6.1 Sol", "codex", { canFast: true })], more: [] },
  { id: "quill", name: "Quill Agent", models: [model("quill-1", "Quill One", "quill")], more: [] },
];

async function harness(options: { rail?: boolean } = {}) {
  const [{ createRoot }, { UiProvider }, { createPopupHost }, { QuickModelColumns }] = await Promise.all([
    import("react-dom/client"),
    import("../src/ui/UiProvider"),
    import("../src/ui/popupHost"),
    import("../src/agent-session/acpmux/QuickModelColumns"),
  ]);
  const shows: NativePopupModel[] = [];
  const updates: NativePopupModel[] = [];
  const listeners = new Set<(event: unknown) => void>();
  const host = createPopupHost(
    (call, params) => {
      if (call === "show") shows.push(params as unknown as NativePopupModel);
      if (call === "update") updates.push(params as unknown as NativePopupModel);
      return Promise.resolve({ shown: true });
    },
    (listener) => {
      listeners.add(listener as (event: unknown) => void);
      return () => listeners.delete(listener as (event: unknown) => void);
    },
  );
  const picked: QuickModel[] = [];
  const levels: string[] = [];
  const fasts: boolean[] = [];
  const closes: boolean[] = [];
  let added = 0;
  const menu: QuickMenu = {
    models: [{ id: "opus", name: "Opus 5.5" }],
    current: "opus",
    onModel: () => {},
    inlineEffort: true,
    effort: {
      levels: [
        { id: "low", name: "Low" },
        { id: "medium", name: "Medium" },
        { id: "high", name: "High" },
      ],
      current: "medium",
      onPick: (value) => levels.push(value),
    },
    fast: { checked: false, onChange: (on) => fasts.push(on) },
    search: { find: () => [], pick: (row) => picked.push(row) },
    ...(options.rail === false
      ? {}
      : {
          families: {
            list: families,
            current: "claude",
            onPick: (row) => picked.push(row),
            onAddHarness: () => added++,
          },
        }),
  };
  const trigger = createRef<HTMLButtonElement>();
  root = createRoot(container);
  act(() =>
    root!.render(
      <UiProvider container={container} popupHost={host}>
        <QuickModelColumns
          open
          onOpenChange={(next) => closes.push(next)}
          trigger={trigger}
          chip={{ "data-menu": "Opus 5.5", label: "Opus 5.5", title: "Opus 5.5" }}
          menu={menu}
          onMore={() => {}}
        >
          Opus 5.5
        </QuickModelColumns>
      </UiProvider>,
    ),
  );
  const latest = () => updates.at(-1) ?? shows.at(-1)!;
  const send = (event: Omit<NativePopupEvent, "popupId" | "revision">) => {
    const current = latest();
    act(() => listeners.forEach((listener) => listener({ ...event, popupId: current.id, revision: current.revision })));
  };
  return { latest, send, picked, levels, fasts, closes, added: () => added, container };
}

const column = (popup: NativePopupModel, id: string) => popup.columns!.find((entry) => entry.id === id)!.rows;
const byLabel = (rows: NativePopupRow[], label: string) => rows.find((row) => row.label === label)!;

test("with a native host the columns draw natively, the chip a plain button and no web popover", async () => {
  const h = await harness();
  const popup = h.latest();
  expect(h.container.querySelector(".acpmux-cols")).toBeNull();
  expect(h.container.querySelector("button.acpmux-picker-button")?.getAttribute("aria-expanded")).toBe("true");
  expect(popup.columns!.map((entry) => [entry.id, entry.width, entry.rail])).toEqual([
    ["rail", 48, true],
    ["models", 149, undefined],
    ["tune", undefined, undefined],
  ]);
  expect(popup.width).toBe(350);
  expect(popup.rail).toBeUndefined();
  expect(popup.search?.submitOnReturn).toBe(true);
});

test("the rail is marks only: Starred first, a monogram for a harness with no symbol, Add harness last", async () => {
  const h = await harness();
  const rail = column(h.latest(), "rail");
  expect(rail[0]!.icon).toBe("browser.omnibox.star");
  expect(byLabel(rail, "Claude Code").mark).toBe("claude");
  expect(byLabel(rail, "Claude Code").checked).toBe(true);
  expect(byLabel(rail, "Quill Agent").monogram).toBe("Q");
  expect(rail.at(-1)!.icon).toBe("action.add");
});

test("the models column checks the running model and the settings column shows its levels and Fast", async () => {
  const h = await harness();
  const models = column(h.latest(), "models");
  expect(byLabel(models, "Opus 5.5").checked).toBe(true);
  expect(byLabel(models, "Opus 5.5").keepOpen).toBe(true);
  const tune = column(h.latest(), "tune");
  expect(tune.filter((row) => row.kind === "action").map((row) => row.label)).toEqual(["High", "Medium", "Low"]);
  expect(byLabel(tune, "Medium").checked).toBe(true);
  expect(tune.find((row) => row.kind === "toggle")?.checked).toBe(false);
  expect(h.latest().highlighted).toBe(byLabel(models, "Opus 5.5").id);
});

test("a level, Fast and a model land at once and keep the menu open", async () => {
  const h = await harness();
  h.send({ type: "pick", id: byLabel(column(h.latest(), "tune"), "High").id });
  expect(h.levels).toEqual(["high"]);
  const fast = column(h.latest(), "tune").find((row) => row.kind === "toggle")!;
  h.send({ type: "change", id: fast.id, value: "true" });
  expect(h.fasts).toEqual([true]);
  h.send({ type: "pick", id: byLabel(column(h.latest(), "models"), "Sonnet 5.5").id });
  expect(h.picked.map((row) => row.id)).toEqual(["sonnet"]);
  expect(h.closes).not.toContain(false);
});

test("the keyboard's highlight on a model shows its settings; on a rail tab it shows that tab", async () => {
  const h = await harness();
  h.send({ type: "highlight", id: byLabel(column(h.latest(), "rail"), "Codex").id, reason: "keyboard" });
  expect(byLabel(column(h.latest(), "rail"), "Codex").checked).toBe(true);
  expect(byLabel(column(h.latest(), "models"), "GPT-6.1 Sol")).toBeDefined();
  h.send({ type: "highlight", id: byLabel(column(h.latest(), "models"), "GPT-6.1 Sol").id, reason: "keyboard" });
  const tune = column(h.latest(), "tune");
  expect(tune.some((row) => row.kind === "toggle")).toBe(true);
  // The pointer's highlight only paints: the tab stays.
  h.send({ type: "highlight", id: byLabel(column(h.latest(), "rail"), "Quill Agent").id, reason: "pointer" });
  expect(byLabel(column(h.latest(), "rail"), "Codex").checked).toBe(true);
});

test("Return runs the highlighted row, then closes", async () => {
  const h = await harness();
  const sonnet = byLabel(column(h.latest(), "models"), "Sonnet 5.5").id;
  h.send({ type: "submit", id: sonnet, value: "" });
  expect(h.picked.map((row) => row.id)).toEqual(["sonnet"]);
  expect(h.closes).toEqual([false]);
});

test("the account avatar sits in the search row and opens its card beside the menu", async () => {
  const h = await harness();
  const accessory = h.latest().searchAccessory!;
  expect(accessory.kind).toBe("submenu");
  expect(accessory.children!.length).toBeGreaterThan(0);
});

test("Add harness closes the menu and opens the harness setup", async () => {
  const h = await harness();
  h.send({ type: "pick", id: column(h.latest(), "rail").at(-1)!.id });
  expect(h.added()).toBe(1);
  expect(h.closes).toContain(false);
});

test("a menu with no rail keeps QuickModelMenu's native list", async () => {
  const h = await harness({ rail: false });
  const popup = h.latest();
  expect(popup.columns).toBeUndefined();
  expect(popup.rows.some((row) => row.label === "Opus 5.5")).toBe(true);
});
