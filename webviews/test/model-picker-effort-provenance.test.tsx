// Capability provenance survives the catalog join and the real model picker.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
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
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test.each(["absent", "empty", "unmarked-empty"] as const)(
  "the real picker preserves %s effort capability",
  async (capability) => {
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const { BUNDLED_MODEL_CATALOG, buildPickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogData");
    const joined = buildPickerCatalog({
      catalog: BUNDLED_MODEL_CATALOG,
      acpmux: [
        {
          id: "custom",
          name: "Custom",
          models: [
            {
              id: "custom-model",
              name: "Custom model",
              ...(capability === "empty" ? { efforts: [] } : {}),
            },
          ],
        },
      ],
    });
    const harness = joined.harnesses.find((entry) => entry.id === "custom")!;
    const model = harness.models.find((entry) => entry.id === "custom-model")!;
    expect(model.efforts).toEqual([]);
    expect(model.effortsDeclared).toBe(capability === "empty");
    const catalog =
      capability === "unmarked-empty"
        ? [
            {
              id: "custom",
              name: "Custom",
              models: [{ id: "custom-model", name: "Custom model", efforts: [] }],
            },
          ]
        : [harness];
    root = (await import("react-dom/client")).createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={catalog}
          harness="custom"
          model="custom-model"
          label="Custom model"
          efforts={[]}
          recents={[]}
          harnessFixed
          onLand={() => {}}
          onEffort={() => {}}
          quick={{
            effort: {
              levels: [
                { id: "low", name: "Low" },
                { id: "high", name: "High" },
                { id: "ultracode", name: "Ultracode" },
              ],
              current: "high",
              onPick() {},
            },
          }}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
    // Wait for the menu to open (a bounded poll, not a fixed sleep).
    const deadline = Date.now() + 5000;
    while (!document.querySelector(".acpmux-quick-menu") && Date.now() < deadline) {
      await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    }
    expect(document.querySelector(".acpmux-quick-menu")).not.toBeNull();
    const segments = await openEffort(document);
    const fallback = [...document.querySelectorAll(".acpmux-quick-sub")].some((row) =>
      row.textContent?.startsWith("Effort"),
    );
    expect(segments.length > 0 || fallback).toBe(capability === "absent");
    expect(document.querySelectorAll('[role^="menuitem"] [role^="menuitem"]')).toHaveLength(0);
  },
);
