import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Select } from "./Select";

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
  "HTMLButtonElement",
  "Element",
  "MouseEvent",
  "PointerEvent",
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
    HTMLButtonElement: win.HTMLButtonElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    PointerEvent: win.MouseEvent,
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

/** The accessible name the way VoiceOver computes it for a button: `aria-labelledby` (each
 * referenced element's text, hidden ones included) wins over `aria-label`, which wins over content. */
function accessibleName(element: Element): string {
  const doc = element.ownerDocument;
  const ids = element.getAttribute("aria-labelledby")?.trim();
  if (ids)
    return ids
      .split(/\s+/)
      .map((id) => doc.getElementById(id)?.textContent?.trim() ?? "")
      .filter(Boolean)
      .join(" ");
  return element.getAttribute("aria-label") ?? element.textContent?.trim() ?? "";
}

const OPTIONS = [
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

const trigger = (doc: Document) => doc.querySelector<HTMLButtonElement>("button.ui-select-button")!;

test("a Select trigger is a menu button named by its label and its current value", () => {
  const doc = render(<Select label="Color scheme" value="dark" options={OPTIONS} onChange={() => {}} />);
  const button = trigger(doc);
  expect(button.getAttribute("aria-haspopup")).toBe("menu");
  expect(accessibleName(button)).toBe("Color scheme Dark");
});

test("a Select labelled by a visible caption names it with the caption and the current value", () => {
  const doc = render(
    <>
      <span id="backend-caption">Backend</span>
      <Select label="Backend" labelledBy="backend-caption" value="light" options={OPTIONS} onChange={() => {}} />
    </>,
  );
  expect(accessibleName(trigger(doc))).toBe("Backend Light");
});

test("a Select with no value yet announces its placeholder after the label", () => {
  const doc = render(<Select label="Folder" value="" placeholder="Choose…" options={OPTIONS} onChange={() => {}} />);
  expect(accessibleName(trigger(doc))).toBe("Folder Choose…");
});

test("the trigger's name follows the value when a pick changes it", () => {
  function Harness() {
    const [value, setValue] = useState("light");
    return (
      <>
        <Select label="Color scheme" value={value} options={OPTIONS} onChange={setValue} />
        <button type="button" id="flip" onClick={() => setValue("dark")}>
          flip
        </button>
      </>
    );
  }
  const doc = render(<Harness />);
  expect(accessibleName(trigger(doc))).toBe("Color scheme Light");
  act(() => {
    doc.getElementById("flip")!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(accessibleName(trigger(doc))).toBe("Color scheme Dark");
});

test("two Selects on one page never share label or value ids", () => {
  const doc = render(
    <>
      <Select label="Color scheme" value="dark" options={OPTIONS} onChange={() => {}} />
      <Select label="Contrast" value="light" options={OPTIONS} onChange={() => {}} />
    </>,
  );
  const names = [...doc.querySelectorAll("button.ui-select-button")].map(accessibleName);
  expect(names).toEqual(["Color scheme Dark", "Contrast Light"]);
});
