// Shared file/folder picker: primary presses select and activate; context-menu gestures move nothing.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DrillList } from "./DrillList";
import { settleReact } from "../../test/support/domTeardown";
import { pressStyleKeys, type StyleKey } from "../../test/support/keyStylePress";
import { configureKeyStyle } from "./keyStyle";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function installDom() {
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
}

function mount(moved: number[], activated: string[]) {
  installDom();
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
  return dom!.window.document.querySelectorAll<HTMLElement>('[role="option"]')[1]!;
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

test("right, middle and macOS Control-click neither move nor open a folder row, and keep focus in the field", () => {
  const moved: number[] = [];
  const activated: string[] = [];
  const second = mount(moved, activated);
  for (const options of [{ button: 2 }, { button: 1 }, { button: 0, ctrlKey: true }]) {
    const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true, ...options });
    act(() => {
      second.dispatchEvent(press);
    });
    // Prevented so the search field keeps focus; the contextmenu event still fires.
    expect(press.defaultPrevented).toBe(true);
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

// `app.keyStyle` (keyStyle.ts): the field keeps its typing; Vim's Esc gives the keyboard to the
// list, where j/k, gg/G, l (enter) and h (up) are the field's moves; Emacs' Ctrl-N/P move from
// the field itself. Standard is today's field, where Esc cancels.
const FOLDERS = ["apps", "bin", "docs", "src"].map((id) => ({ id }));

function Picker({ log }: { log: string[] }) {
  const [highlight, setHighlight] = useState(0);
  return (
    <DrillList
      sections={[{ id: "folders", items: FOLDERS }]}
      getKey={(item) => item.id}
      renderItem={(item) => item.id}
      highlight={highlight}
      onHighlight={setHighlight}
      query=""
      onQueryChange={() => {}}
      onEnter={(item) => log.push(`enter ${item?.id}`)}
      onUp={() => log.push("up")}
      onChoose={(item) => log.push(`choose ${item?.id}`)}
      onCancel={() => log.push("cancel")}
      onActivate={() => {}}
      label="Folder"
      listLabel="Folders"
    />
  );
}

function drive(style: string, keys: StyleKey[], log: string[] = []) {
  installDom();
  act(() => configureKeyStyle({ "app.keyStyle": style }));
  act(() => root!.render(<Picker log={log} />));
  const doc = dom!.window.document;
  for (const key of keys)
    pressStyleKeys(dom!.window, doc.activeElement ?? doc.body, [key], (dispatch) => act(dispatch));
  return {
    selected: doc.querySelector('[role="option"][aria-selected="true"]')?.textContent,
    focus: doc.activeElement?.getAttribute("role"),
  };
}

test.each([
  ["vim", ["j"], "apps", "combobox"],
  ["vim", ["Escape"], "apps", "listbox"],
  ["vim", ["Escape", "j", "j"], "docs", "listbox"],
  ["vim", ["Escape", "G", "k"], "docs", "listbox"],
  ["vim", ["Escape", "G", "g", "g"], "apps", "listbox"],
  ["vim", ["Escape", "j", "/"], "bin", "combobox"],
  ["emacs", ["C-n", "C-n"], "docs", "combobox"],
  ["emacs", ["C-n", "C-n", "C-p"], "bin", "combobox"],
  ["standard", ["Escape", "j"], "apps", "combobox"],
] as [string, StyleKey[], string, string][])(
  "%s %j: %s highlighted, the %s has the keyboard",
  (style, keys, row, focus) => {
    expect(drive(style, keys)).toEqual({ selected: row, focus });
  },
);

test("Vim in the list: l enters, h goes up, Esc cancels", () => {
  const log: string[] = [];
  drive("vim", ["Escape", "j", "l", "h", "Escape"], log);
  expect(log).toEqual(["enter bin", "up", "cancel"]);
});

test("Standard: Esc on the empty field cancels, as before", () => {
  const log: string[] = [];
  drive("standard", ["Escape"], log);
  expect(log).toEqual(["cancel"]);
});
