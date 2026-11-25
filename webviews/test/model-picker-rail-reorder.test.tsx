import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
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
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

// Lucas 2026-11-25: "make it so that the harnesses are re-arrangeable in the model picker (excluding
// star)". A drag moves a harness tab along the rail and keeps the order (modelPickerOrder.ts);
// Starred stays first and never moves; the release picks nothing.
const claude = { id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }], pickable: true };
const codex = { id: "codex", name: "Codex", models: [{ id: "gpt-6.2-sol", name: "GPT-6.2 Sol" }], pickable: true };
const opencode = {
  id: "opencode",
  name: "OpenCode",
  models: [{ id: "opencode/big-pickle", name: "Big Pickle" }],
  pickable: true,
};

test("orderTabs and movedOrder: Starred first, the named tabs in order, the rest after", async () => {
  const { orderTabs, movedOrder } = await import("../src/agent-session/acpmux/modelPickerOrder");
  const tabs = [{ key: "star", starred: true }, { key: "claude" }, { key: "openai" }, { key: "opencode" }];
  expect(orderTabs(tabs, []).map((tab) => tab.key)).toEqual(["star", "claude", "openai", "opencode"]);
  expect(orderTabs(tabs, ["opencode", "claude"]).map((tab) => tab.key)).toEqual([
    "star",
    "opencode",
    "claude",
    "openai",
  ]);
  expect(movedOrder(["claude", "openai", "opencode"], "opencode", 0)).toEqual(["opencode", "claude", "openai"]);
  expect(movedOrder(["claude", "openai", "opencode"], "claude", 2)).toEqual(["openai", "opencode", "claude"]);
});

test("a drag moves a harness tab up the rail, keeps the order, and picks nothing", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const { modelPickerOrder, setModelPickerOrder } = await import("../src/agent-session/acpmux/modelPickerOrder");
  setModelPickerOrder([]);
  const picked: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ModelPicker
        catalog={[claude, codex, opencode]}
        harness="claude"
        model="opus"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={(id) => picked.push(id)}
        onCombo={(combo) => picked.push(combo.model)}
        onHarness={(id) => picked.push(`harness:${id}`)}
        onEffort={() => {}}
        quick={{}}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  await settle();
  const doc = dom.window.document;
  const tabs = () => [...doc.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')];
  const names = () => tabs().map((tab) => tab.getAttribute("aria-label"));
  expect(names()).toEqual(["Starred", "Claude Code", "Codex", "OpenCode"]);
  // Starred never moves.
  expect(tabs()[0]!.hasAttribute("data-movable")).toBe(false);
  // Each tab 32px tall with a 4px gap, in a rail at the top of the page.
  const rail = doc.querySelector<HTMLElement>(".acpmux-cols-rail")!;
  rail.getBoundingClientRect = () => ({ top: 0, left: 0, width: 40, height: 400, right: 40, bottom: 400 }) as DOMRect;
  tabs().forEach((tab, index) => {
    tab.getBoundingClientRect = () =>
      ({ top: index * 36, left: 0, width: 32, height: 32, right: 32, bottom: index * 36 + 32 }) as DOMRect;
  });
  const opencodeTab = tabs()[3]!;
  const pointer = (type: string, y: number) =>
    new dom.window.PointerEvent(type, {
      bubbles: true,
      cancelable: true,
      button: 0,
      pointerId: 1,
      clientX: 16,
      clientY: y,
    });
  await act(async () => {
    opencodeTab.dispatchEvent(pointer("pointerdown", 124));
    dom.window.dispatchEvent(pointer("pointermove", 100));
    // Past the top: the tab stops at the first movable place, under Starred.
    dom.window.dispatchEvent(pointer("pointermove", 4));
  });
  expect(opencodeTab.hasAttribute("data-lifted")).toBe(true);
  await act(async () => {
    dom.window.dispatchEvent(pointer("pointerup", 4));
    opencodeTab.click();
  });
  await settle();
  expect(modelPickerOrder()).toEqual(["opencode", "claude", "openai"]);
  expect(names()).toEqual(["Starred", "OpenCode", "Claude Code", "Codex"]);
  // The release's click picked no tab and no model.
  expect(picked).toEqual([]);
  setModelPickerOrder([]);
});
