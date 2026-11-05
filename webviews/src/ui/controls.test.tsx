// The shared controls (ui/Button, Switch, Tabs, Input) keep Base UI's keyboard and focus contract:
// a button is a real button that a disabled state silences, a switch is role switch and toggles,
// tabs move with the arrow keys and mark the active tab, and a field takes focus and text.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Button } from "./Button";
import { Input } from "./Input";
import { Switch } from "./Switch";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "./Tabs";

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

test("Button is a focusable button with our variant and size, and disabled silences it", () => {
  let pressed = 0;
  const doc = render(
    <>
      <Button onClick={() => (pressed += 1)}>Run</Button>
      <Button variant="solid" size="lg" disabled onClick={() => (pressed += 1)}>
        Off
      </Button>
    </>,
  );
  const [run, off] = [...doc.querySelectorAll<HTMLButtonElement>("button")];
  expect(run!.type).toBe("button");
  expect(run!.dataset.variant).toBe("subtle");
  expect(run!.dataset.size).toBe("md");
  run!.focus();
  expect(doc.activeElement === run).toBe(true);
  click(run!);
  expect(pressed).toBe(1);
  expect(off!.dataset.variant).toBe("solid");
  expect(off!.disabled).toBe(true);
  click(off!);
  expect(pressed).toBe(1);
});

test("Switch is role switch, toggles on click and reports its state", () => {
  const changes: boolean[] = [];
  const doc = render(<Switch aria-label="Fast mode" onCheckedChange={(checked) => changes.push(checked)} />);
  const control = doc.querySelector<HTMLElement>('[role="switch"]')!;
  expect(control).not.toBeNull();
  expect(control.dataset.size).toBe("md");
  expect(control.getAttribute("aria-checked")).toBe("false");
  click(control);
  expect(changes).toEqual([true]);
  expect(control.getAttribute("aria-checked")).toBe("true");
  expect(control.hasAttribute("data-checked")).toBe(true);
});

test("Tabs mark the active tab, move with the arrow keys, and a disabled tab never activates", async () => {
  const doc = render(
    <Tabs variant="segmented" defaultValue="a">
      <TabsList aria-label="Sections">
        <TabsTrigger value="a">A</TabsTrigger>
        <TabsTrigger value="b" disabled>
          B
        </TabsTrigger>
        <TabsTrigger value="c">C</TabsTrigger>
      </TabsList>
      <TabsContent value="a">Panel A</TabsContent>
      <TabsContent value="c">Panel C</TabsContent>
    </Tabs>,
  );
  const list = doc.querySelector<HTMLElement>('[role="tablist"]')!;
  expect(list.dataset.variant).toBe("segmented");
  const tabs = [...doc.querySelectorAll<HTMLElement>('[role="tab"]')];
  expect(tabs.map((tab) => tab.getAttribute("aria-selected"))).toEqual(["true", "false", "false"]);
  const focused = () => tabs.indexOf(doc.activeElement as HTMLElement);
  act(() => tabs[0]!.focus());
  expect(focused()).toBe(0);
  // Base UI keeps a disabled tab focusable (WAI-ARIA's tabs pattern), so the arrows stop on it.
  key(tabs[0]!, "ArrowRight");
  await settle();
  expect(focused()).toBe(1);
  click(tabs[1]!);
  expect(tabs[1]!.getAttribute("aria-selected")).toBe("false");
  key(tabs[1]!, "ArrowRight");
  await settle();
  expect(focused()).toBe(2);
  key(tabs[2]!, "ArrowLeft");
  await settle();
  expect(focused()).toBe(1);
  click(tabs[2]!);
  expect(tabs[2]!.getAttribute("aria-selected")).toBe("true");
  expect(tabs[2]!.hasAttribute("data-active")).toBe(true);
});

test("Input takes focus and text and keeps our variant", () => {
  let value = "";
  const doc = render(
    <Input aria-label="Search" variant="outline" onChange={(event) => (value = event.currentTarget.value)} />,
  );
  const field = doc.querySelector<HTMLInputElement>("input")!;
  expect(field.dataset.variant).toBe("outline");
  expect(field.classList.contains("ui-field")).toBe(true);
  act(() => field.focus());
  expect(doc.activeElement === field).toBe(true);
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "opus");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  expect(value).toBe("opus");
});
