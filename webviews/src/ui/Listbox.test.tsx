// Recent-file and recent-repository rows open on the primary mouse button only.
// Right-click must reach the system's menu, and middle-click must not navigate away.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Listbox, sameDrawn } from "./Listbox";
import { settleReact } from "../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function mount(ran: string[]) {
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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <Listbox
        items={[{ id: "recent", title: "Recent file" }]}
        getKey={(item) => item.id}
        textValue={(item) => item.title}
        renderItem={(item) => item.title}
        label="Recent files"
        autoFocus={false}
        onOpen={(item) => ran.push(item.id)}
      />,
    ),
  );
  return dom.window.document.querySelector<HTMLElement>('[role="option"]')!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = null;
  await settleReact();
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

test("a row's drawn output compares by value: elements by type, key and props, functions by identity", () => {
  function Label(_: { text: string; children?: unknown }) {
    return null;
  }
  const handler = () => {};
  expect(sameDrawn("a", "a")).toBe(true);
  expect(sameDrawn(1, 2)).toBe(false);
  expect(sameDrawn(null, undefined)).toBe(false);
  expect(sameDrawn(<Label text="a" />, <Label text="a" />)).toBe(true);
  expect(sameDrawn(<Label text="a" />, <Label text="b" />)).toBe(false);
  expect(sameDrawn(<Label key="1" text="a" />, <Label key="2" text="a" />)).toBe(false);
  expect(sameDrawn(<Label text="a" />, <span>a</span>)).toBe(false);
  expect(
    sameDrawn(
      <span className="x">{["a", <b key="b">b</b>]}</span>,
      <span className="x">{["a", <b key="b">b</b>]}</span>,
    ),
  ).toBe(true);
  expect(sameDrawn(<span>{["a", <b key="b">b</b>]}</span>, <span>{["a", <b key="b">c</b>]}</span>)).toBe(false);
  expect(sameDrawn([<i key="1" />], [<i key="1" />, <i key="2" />])).toBe(false);
  expect(sameDrawn(<button aria-label="x" onClick={handler} />, <button aria-label="x" onClick={handler} />)).toBe(
    true,
  );
  expect(sameDrawn(<button aria-label="x" onClick={() => {}} />, <button aria-label="x" onClick={() => {}} />)).toBe(
    false,
  );
  // A plain object (a style) is not drawn output: a new one counts as a change.
  expect(sameDrawn(<span style={{ color: "red" }} />, <span style={{ color: "red" }} />)).toBe(false);
  expect(sameDrawn({ props: {} }, { props: {} })).toBe(false);
  // Nesting past the bound counts as a change.
  let deep: unknown = "x";
  let same: unknown = "x";
  for (let level = 0; level < 20; level++) {
    deep = <span>{deep as string}</span>;
    same = <span>{same as string}</span>;
  }
  expect(sameDrawn(deep, same)).toBe(false);
});
