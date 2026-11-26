// Recent-file and recent-repository rows open on the primary mouse button only.
// Right-click must reach the system's menu, and middle-click must not navigate away.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Listbox } from "./Listbox";
import { settleReact } from "../../test/support/domTeardown";
import { pressStyleKeys, type StyleKey } from "../../test/support/keyStylePress";
import { configureKeyStyle } from "./keyStyle";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function mount(ran: string[], items = [{ id: "recent", title: "Recent file" }]) {
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
        items={items}
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
  configureKeyStyle({});
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

// `app.keyStyle` (keyStyle.ts): the list's own moves under Vim's and Emacs' keys; Standard is
// today's list, where j is a typeahead letter.
const FILES = ["alpha", "beta", "gamma", "jupiter"].map((title) => ({ id: title, title }));

function styled(style: string, keys: StyleKey[], opened: string[] = []) {
  act(() => configureKeyStyle({ "app.keyStyle": style }));
  mount(opened, FILES);
  const list = dom!.window.document.querySelector<HTMLElement>('[role="listbox"]')!;
  const last = pressStyleKeys(dom!.window, list, keys, (dispatch) => act(dispatch));
  const selected = list.querySelector('[aria-selected="true"]')?.textContent;
  return { selected, last };
}

test.each([
  ["vim", ["j", "j"], "gamma"],
  ["vim", ["j", "j", "k"], "beta"],
  ["vim", ["G"], "jupiter"],
  ["vim", ["G", "g", "g"], "alpha"],
  ["emacs", ["C-n", "C-n", "C-p"], "beta"],
  ["emacs", ["C-e"], "jupiter"],
  ["emacs", ["C-e", "C-a"], "alpha"],
  // Standard is today's list: j is a typeahead letter, Ctrl-N the app's.
  ["standard", ["j"], "jupiter"],
  ["standard", ["C-n"], "alpha"],
] as [string, StyleKey[], string][])("%s %j highlights %s", (style, keys, expected) => {
  const { selected, last } = styled(style, keys);
  expect(selected).toBe(expected);
  if (style === "standard" && keys[0] === "C-n") expect(last?.defaultPrevented).toBe(false);
});

test("Vim: l opens the highlighted row", () => {
  const opened: string[] = [];
  styled("vim", ["j", "l"], opened);
  expect(opened).toEqual(["beta"]);
});

test("Vim: Esc is not the list's, so it goes on to the popup that closes on it", () => {
  expect(styled("vim", ["Escape"]).last?.defaultPrevented).toBe(false);
});
