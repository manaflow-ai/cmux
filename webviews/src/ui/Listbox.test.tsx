// Recent-file and recent-repository rows open on the primary mouse button only.
// Right-click must reach the system's menu, and middle-click must not navigate away.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Listbox, type ListboxProps } from "./Listbox";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

type Item = { id: string; title: string };

function mount(ran: string[], extra: Partial<ListboxProps<Item>> = {}) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', {
    url: "http://localhost/",
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <Listbox<Item>
        items={[{ id: "recent", title: "Recent file" }]}
        getKey={(item) => item.id}
        textValue={(item) => item.title}
        renderItem={(item) => item.title}
        label="Recent files"
        autoFocus={false}
        onOpen={(item) => ran.push(item.id)}
        {...extra}
      />,
    ),
  );
  return dom.window.document.querySelector<HTMLElement>('[role="option"]')!;
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

test("context-menu presses (right, middle and Mac Control-click) never open a recent item", () => {
  const ran: string[] = [];
  const row = mount(ran);
  for (const options of [{ button: 2 }, { button: 1 }, { button: 0, ctrlKey: true }]) {
    const event = new MouseEvent("mousedown", { bubbles: true, cancelable: true, ...options });
    act(() => {
      row.dispatchEvent(event);
    });
    expect(event.defaultPrevented).toBe(false);
    expect(ran).toEqual([]);
  }
});

test("a primary press still opens the chosen recent item immediately", () => {
  const ran: string[] = [];
  const row = mount(ran);
  const event = new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
  act(() => {
    row.dispatchEvent(event);
  });
  expect(event.defaultPrevented).toBe(true);
  expect(ran).toEqual(["recent"]);
});

test("the list's own keys come first, and a key they take is not the list's", () => {
  const ran: string[] = [];
  const seen: string[] = [];
  const row = mount(ran, {
    activeIndex: 0,
    focusable: true,
    onKeyDown: (event) => {
      seen.push(event.key);
      if (event.key === "Enter") event.preventDefault();
    },
  });
  const list = row.parentElement!;
  // A controlled highlight with no outside field still takes Tab.
  expect(list.tabIndex).toBe(0);
  for (const key of ["Enter", " "]) {
    act(() => {
      list.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  }
  expect(seen).toEqual(["Enter", " "]);
  expect(ran).toEqual(["recent"]);
});
