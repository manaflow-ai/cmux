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
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

describe("closed model picker catalog work", () => {
  for (const compact of [false, true]) {
    test(compact ? "compact menu loads models on first click" : "full picker loads models on first click", async () => {
      const { createRoot } = await import("react-dom/client");
      const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
      let reads = 0;
      const catalog = [
        {
          id: "claude",
          name: "Claude Code",
          get models() {
            reads++;
            return [
              { id: "opus", name: "Opus 5.5" },
              { id: "sonnet", name: "Sonnet 5.5" },
            ];
          },
        },
      ];
      const picked: string[] = [];
      const render = (label = "Opus 5.5") => (
        <ModelPicker
          catalog={catalog}
          harness="claude"
          model="opus"
          label={label}
          efforts={[]}
          recents={[]}
          onLand={(id) => picked.push(id)}
          onEffort={() => {}}
          quick={compact ? {} : undefined}
        />
      );
      root = createRoot(host);
      await act(async () => root!.render(render()));
      expect(host.textContent).toContain("Opus 5.5");
      expect(reads).toBe(0);
      await act(async () => root!.render(render("Claude Opus 5.5")));
      expect(reads).toBe(0);
      await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
      await settle();
      expect(reads).toBeGreaterThan(0);
      const items = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitemradio"],[role="option"]')];
      const sonnet = items.find((item) => item.textContent?.includes("Sonnet 5.5"));
      expect(sonnet).toBeDefined();
      await act(async () => sonnet!.click());
      expect(picked).toEqual(["sonnet"]);
      await settle();
      // Closing retains the initialized list through its exit; reopening still owns selection.
      await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
      await settle();
      const reopened = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitemradio"],[role="option"]')];
      const opus = reopened.find((item) => item.textContent?.includes("Opus 5.5"));
      expect(opus).toBeDefined();
      const reopenedSonnet = reopened.find((item) => item.textContent?.includes("Sonnet 5.5"));
      expect(reopenedSonnet).toBeDefined();
      await act(async () => reopenedSonnet!.click());
      expect(picked).toEqual(["sonnet", "sonnet"]);
    });
  }
});
