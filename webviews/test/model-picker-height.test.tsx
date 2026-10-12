import { afterAll, beforeAll, expect, test } from "bun:test";
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
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let menuHeight = 148;
let originalRect: typeof HTMLElement.prototype.getBoundingClientRect;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    ShadowRoot: window.ShadowRoot,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
  });
  originalRect = window.HTMLElement.prototype.getBoundingClientRect;
  window.HTMLElement.prototype.getBoundingClientRect = function () {
    if (this.classList.contains("acpmux-mp")) {
      return {
        bottom: 520,
        height: menuHeight,
        left: 24,
        right: 334,
        top: 520 - menuHeight,
        width: 310,
        x: 24,
        y: 520 - menuHeight,
        toJSON: () => ({}),
      };
    }
    if (this.classList.contains("acpmux-picker-button")) {
      return {
        bottom: 548,
        height: 28,
        left: 24,
        right: 144,
        top: 520,
        width: 120,
        x: 24,
        y: 520,
        toJSON: () => ({}),
      };
    }
    return originalRect.call(this);
  };
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  const window = scope.window as Window & typeof globalThis;
  if (window?.HTMLElement) window.HTMLElement.prototype.getBoundingClientRect = originalRect;
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the model picker keeps its measured height while filtering in one opening", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const catalog = [
    {
      id: "claude",
      name: "Claude Code",
      models: [
        { id: "opus", name: "Opus 5.5" },
        { id: "sonnet", name: "Sonnet 5.5" },
        { id: "haiku", name: "Haiku 4.5" },
      ],
    },
  ];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ModelPicker
        catalog={catalog}
        harness="claude"
        model="opus"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={() => undefined}
        onEffort={() => undefined}
      />,
    ),
  );

  await act(async () => {
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
  });
  const menu = host.querySelector<HTMLElement>(".acpmux-mp")!;
  expect(menu.style.height).toBe("148px");

  menuHeight = 224;
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
  await act(async () => {
    search.value = "Sonnet";
    search.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  expect(menu.style.height).toBe("148px");

  await act(async () => {
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
  });
  expect(host.querySelector(".acpmux-mp")).toBeNull();

  menuHeight = 212;
  await act(async () => {
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
  });
  expect(host.querySelector<HTMLElement>(".acpmux-mp")!.style.height).toBe("212px");
});
