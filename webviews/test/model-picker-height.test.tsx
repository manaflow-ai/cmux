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

// The open picker's height is bounded, never pinned (d9ce210e, Lawrence 2026-10-13): at most the
// chip's room, at least 220 px when room permits and the height it measured when it opened, so a narrowing
// search does not shrink it and a menu that opened before its models never collapses to its search field.
const px = (value: string) => Number.parseFloat(value);
const bounds = (menu: HTMLElement) => ({
  pinned: menu.style.height,
  min: px(menu.style.minHeight),
  max: px(menu.style.maxHeight),
});

test("the model picker keeps its measured height while filtering in one opening, within its bounds", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const { MODEL_PICKER_MIN_HEIGHT } = await import("../src/agent-session/acpmux/modelPickerLayout");
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
  const toggle = async () => {
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
    });
  };

  // Opened at 300 px: at least that, never more than the room, and no fixed height.
  menuHeight = 300;
  await toggle();
  const menu = host.querySelector<HTMLElement>(".acpmux-mp")!;
  const opened = bounds(menu);
  expect(opened.pinned).toBe("");
  expect(opened.max).toBeGreaterThan(0);
  expect(opened.min).toBe(Math.min(opened.max, 300));

  // A narrowing search measures shorter; the bounds hold steady.
  menuHeight = 224;
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
  await act(async () => {
    search.value = "Sonnet";
    search.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  expect(bounds(menu)).toEqual(opened);

  await toggle();
  expect(host.querySelector(".acpmux-mp")).toBeNull();

  // A new opening measures again.
  menuHeight = 260;
  await toggle();
  const reopened = bounds(host.querySelector<HTMLElement>(".acpmux-mp")!);
  expect(reopened.min).toBe(Math.min(reopened.max, 260));
  await toggle();

  // Opened before its models arrived (its search field alone, 148 px): the floor, not 148 px.
  menuHeight = 148;
  await toggle();
  const early = bounds(host.querySelector<HTMLElement>(".acpmux-mp")!);
  expect(early.pinned).toBe("");
  expect(early.min).toBe(Math.min(early.max, MODEL_PICKER_MIN_HEIGHT));
});

test("picker grows to the measured room and shrinks to a short viewport", async () => {
  const { pickerHeightBounds } = await import("../src/agent-session/acpmux/modelPickerLayout");
  expect(pickerHeightBounds(900, 300)).toEqual({ maxHeight: 900, minHeight: 300 });
  expect(pickerHeightBounds(150, 300)).toEqual({ maxHeight: 150, minHeight: 150 });
});
