// The standalone Toggle and ToggleGroup (ui/Toggle.tsx) keep Base UI's contract: a toggle is a real
// button with aria-pressed that Space, Return and a click flip; a group is a named role group with one
// Tab stop whose arrows rove and loop along its orientation; single choice keeps one pressed and
// `multiple` keeps several.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Toggle, ToggleGroup } from "./Toggle";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    HTMLInputElement: win.HTMLInputElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle,
    requestAnimationFrame: win.requestAnimationFrame.bind(win),
    cancelAnimationFrame: win.cancelAnimationFrame.bind(win),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const click = (element: Element) =>
  act(() => {
    element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  });

const key = (element: Element, name: string) =>
  act(() => {
    element.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });

/** Lets Base UI's focus move land: the composite list focuses the next tab in a microtask. */
const settle = () => act(async () => {});

const buttons = (doc: Document) => [...doc.querySelectorAll<HTMLButtonElement>("button")];

test("Toggle is a button with aria-pressed that a click flips, drawn as our button", () => {
  const changes: boolean[] = [];
  const doc = render(<Toggle onPressedChange={(pressed) => changes.push(pressed)}>Wrap lines</Toggle>);
  const [toggle] = buttons(doc);
  expect(toggle!.type).toBe("button");
  expect(toggle!.getAttribute("aria-pressed")).toBe("false");
  expect(toggle!.classList.contains("ui-btn")).toBe(true);
  expect(toggle!.dataset.variant).toBe("ghost");
  expect(toggle!.dataset.size).toBe("md");
  click(toggle!);
  expect(changes).toEqual([true]);
  expect(toggle!.getAttribute("aria-pressed")).toBe("true");
  expect(toggle!.hasAttribute("data-pressed")).toBe(true);
  click(toggle!);
  expect(toggle!.getAttribute("aria-pressed")).toBe("false");
});

test("ToggleGroup is a named group with one Tab stop whose arrows rove and loop", async () => {
  const doc = render(
    <ToggleGroup aria-label="Diff view" defaultValue={["split"]} variant="segmented">
      <Toggle value="split">Split</Toggle>
      <Toggle value="unified">Unified</Toggle>
      <Toggle value="files">Files</Toggle>
    </ToggleGroup>,
  );
  const group = doc.querySelector<HTMLElement>('[role="group"]')!;
  expect(group).not.toBeNull();
  expect(group.getAttribute("aria-label")).toBe("Diff view");
  expect(group.dataset.variant).toBe("segmented");
  const toggles = buttons(doc);
  // The group's look reaches every toggle.
  expect(toggles.map((toggle) => toggle.dataset.variant)).toEqual(["segmented", "segmented", "segmented"]);
  expect(toggles.map((toggle) => toggle.getAttribute("aria-pressed"))).toEqual(["true", "false", "false"]);
  // Roving focus: one toggle is in the Tab order.
  expect(toggles.filter((toggle) => toggle.tabIndex === 0)).toHaveLength(1);
  const focused = () => toggles.indexOf(doc.activeElement as HTMLButtonElement);
  act(() => toggles[0]!.focus());
  key(toggles[0]!, "ArrowRight");
  await settle();
  expect(focused()).toBe(1);
  key(toggles[1]!, "ArrowRight");
  await settle();
  expect(focused()).toBe(2);
  key(toggles[2]!, "ArrowRight");
  await settle();
  expect(focused()).toBe(0);
  key(toggles[0]!, "ArrowLeft");
  await settle();
  expect(focused()).toBe(2);
});

test("a single-choice group keeps one pressed; a multiple group keeps several", () => {
  const single: string[][] = [];
  const doc = render(
    <>
      <ToggleGroup aria-label="View" defaultValue={["a"]} onValueChange={(next) => single.push(next)}>
        <Toggle value="a">A</Toggle>
        <Toggle value="b">B</Toggle>
      </ToggleGroup>
      <ToggleGroup aria-label="Format" multiple defaultValue={["bold"]}>
        <Toggle value="bold">Bold</Toggle>
        <Toggle value="italic">Italic</Toggle>
      </ToggleGroup>
    </>,
  );
  const [a, b, bold, italic] = buttons(doc);
  click(b!);
  expect(single).toEqual([["b"]]);
  expect([a, b].map((toggle) => toggle!.getAttribute("aria-pressed"))).toEqual(["false", "true"]);
  click(italic!);
  expect([bold, italic].map((toggle) => toggle!.getAttribute("aria-pressed"))).toEqual(["true", "true"]);
});

test("a vertical group moves with Up and Down", async () => {
  const doc = render(
    <ToggleGroup aria-label="Sides" orientation="vertical">
      <Toggle value="top">Top</Toggle>
      <Toggle value="bottom">Bottom</Toggle>
    </ToggleGroup>,
  );
  const group = doc.querySelector<HTMLElement>('[role="group"]')!;
  expect(group.dataset.orientation).toBe("vertical");
  const toggles = buttons(doc);
  act(() => toggles[0]!.focus());
  key(toggles[0]!, "ArrowDown");
  await settle();
  expect(doc.activeElement === toggles[1]).toBe(true);
  key(toggles[1]!, "ArrowUp");
  await settle();
  expect(doc.activeElement === toggles[0]).toBe(true);
});
