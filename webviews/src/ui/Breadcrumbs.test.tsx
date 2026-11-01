// The shared folder breadcrumb leaves system context gestures alone and stays keyboard accessible.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Breadcrumbs } from "./Breadcrumbs";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function mount(opened: string[]) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', {
    url: "http://localhost/",
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "MouseEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => {
    root!.render(
      <Breadcrumbs
        label="Folders"
        crumbs={[{ label: "Home", path: "/home" }, { label: "Project", path: "/home/project" }]}
        onNavigate={(crumb) => opened.push(crumb.path)}
      />,
    );
  });
  return dom.window.document.querySelector<HTMLButtonElement>(".ui-crumb")!;
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

test("right, middle and Control-click preserve the system context gesture and do not navigate", () => {
  const opened: string[] = [];
  const crumb = mount(opened);
  for (const options of [{ button: 2 }, { button: 1 }, { button: 0, ctrlKey: true }]) {
    const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true, ...options });
    act(() => {
      crumb.dispatchEvent(press);
      crumb.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ...options }));
    });
    expect(press.defaultPrevented).toBe(false);
  }
  expect(opened).toEqual([]);
});

test("ordinary primary and keyboard-generated clicks still navigate without taking mouse focus", () => {
  const opened: string[] = [];
  const crumb = mount(opened);
  const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
  act(() => {
    crumb.dispatchEvent(press);
    crumb.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
    crumb.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
  });
  expect(press.defaultPrevented).toBe(true);
  expect(opened).toEqual(["/home", "/home"]);
});
