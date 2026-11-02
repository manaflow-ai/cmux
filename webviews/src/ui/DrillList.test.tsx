// Shared file/folder picker: primary presses select and activate; context-menu gestures stay native.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DrillList } from "./DrillList";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function mount(moved: number[], activated: string[]) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', {
    url: "http://localhost/",
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => {
    root!.render(
      <DrillList
        sections={[{ id: "folders", items: [{ id: "first" }, { id: "second" }] }]}
        getKey={(item) => item.id}
        renderItem={(item) => item.id}
        highlight={0}
        onHighlight={(index) => moved.push(index)}
        query=""
        onQueryChange={() => {}}
        onEnter={() => {}}
        onUp={() => {}}
        onChoose={() => {}}
        onCancel={() => {}}
        onActivate={(item) => activated.push(item.id)}
        label="Folder"
        listLabel="Folders"
        autoFocus={false}
      />,
    );
  });
  return dom.window.document.querySelectorAll<HTMLElement>('[role="option"]')[1]!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = null;
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("right, middle and macOS Control-click leave folder selection and native mouse actions alone", () => {
  const moved: number[] = [];
  const activated: string[] = [];
  const second = mount(moved, activated);
  for (const options of [{ button: 2 }, { button: 1 }, { button: 0, ctrlKey: true }]) {
    const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true, ...options });
    act(() => {
      second.dispatchEvent(press);
    });
    expect(press.defaultPrevented).toBe(false);
    const double = new MouseEvent("dblclick", { bubbles: true, cancelable: true, ...options });
    act(() => {
      second.dispatchEvent(double);
    });
  }
  expect(moved).toEqual([]);
  expect(activated).toEqual([]);
});

test("primary press highlights the row and an unmodified double-click activates it", () => {
  const moved: number[] = [];
  const activated: string[] = [];
  const second = mount(moved, activated);
  const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
  act(() => {
    second.dispatchEvent(press);
    second.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true, button: 0 }));
  });
  expect(press.defaultPrevented).toBe(true);
  expect(moved).toEqual([1]);
  expect(activated).toEqual(["second"]);
});
