import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PaletteMenu } from "./PaletteMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("composition Enter does not dispatch or close, then plain Enter does", async () => {
  let picks = 0;
  await act(async () =>
    root!.render(
      <PaletteMenu
        label="Add"
        button={<span>+</span>}
        sections={[
          {
            title: "Tools",
            choices: [{ id: "tool", name: "Tool", description: "Run tool" }],
            onPick: () => {
              picks += 1;
            },
          },
        ]}
      />,
    ),
  );
  const trigger = container.querySelector<HTMLButtonElement>(".acpmux-picker-button")!;
  await act(async () => trigger.click());
  const input = container.querySelector<HTMLInputElement>("input[role=combobox]")!;
  const composing = new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, isComposing: true });
  Object.defineProperty(composing, "keyCode", { value: 229 });
  await act(async () => input.dispatchEvent(composing));
  expect(picks).toBe(0);
  expect(trigger.getAttribute("aria-expanded")).toBe("true");
  await act(async () => input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(picks).toBe(1);
  expect(trigger.getAttribute("aria-expanded")).toBe("false");
});
