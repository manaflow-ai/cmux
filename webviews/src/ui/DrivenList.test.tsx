// Lists a search field drives (DrivenList.tsx): the field keeps the keyboard; a row picks on a
// click, Return or Space, and a press on it never takes focus.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DrivenList, DrivenRow, InlineCard } from "./DrivenList";
import { pressStyleKeys, type StyleKey } from "../../test/support/keyStylePress";
import { configureKeyStyle, type ListCommand } from "./keyStyle";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function installDom() {
  // A second list in one test replaces the first; the globals saved are the ones before both.
  act(() => root?.unmount());
  dom?.window.close();
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  return dom.window.document;
}

function mount(picks: string[]) {
  installDom();
  act(() => {
    root!.render(
      <>
        <input aria-label="Search" aria-activedescendant="row-b" />
        <DrivenList kind="tablist" label="Harness">
          <DrivenRow kind="tab" aria-selected onPick={() => picks.push("tab")}>
            Claude
          </DrivenRow>
        </DrivenList>
        <DrivenList kind="listbox" label="Model">
          <DrivenRow id="row-a" kind="option" aria-selected={false} onPick={() => picks.push("a")}>
            Opus
          </DrivenRow>
          <DrivenRow id="row-b" kind="option" aria-selected onPick={() => picks.push("b")}>
            Sonnet
          </DrivenRow>
          <DrivenRow tabbable kind="button" onPick={() => picks.push("add")}>
            Add
          </DrivenRow>
        </DrivenList>
        <InlineCard label="Account">Card</InlineCard>
      </>,
    );
  });
  return dom!.window.document;
}

afterEach(() => {
  configureKeyStyle({});
  act(() => root?.unmount());
  root = null;
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("the parts carry their roles and names", () => {
  const doc = mount([]);
  expect(doc.querySelector('[role="tablist"]')?.getAttribute("aria-label")).toBe("Harness");
  expect(doc.querySelector('[role="listbox"]')?.getAttribute("aria-label")).toBe("Model");
  expect(doc.querySelectorAll('[role="listbox"] [role="option"]')).toHaveLength(2);
  expect(doc.querySelector('[role="tab"]')?.getAttribute("aria-selected")).toBe("true");
  expect(doc.querySelector('[role="dialog"]')?.getAttribute("aria-label")).toBe("Account");
});

test("only tabbable rows take Tab; the others are reached through the field", () => {
  const doc = mount([]);
  expect(doc.getElementById("row-a")?.tabIndex).toBe(-1);
  expect(doc.querySelector<HTMLElement>('[role="button"]')?.tabIndex).toBe(0);
});

test("a press on a row keeps the field's focus, and a click picks the row", () => {
  const picks: string[] = [];
  const doc = mount(picks);
  const field = doc.querySelector("input")!;
  field.focus();
  const row = doc.getElementById("row-a")!;
  const press = new dom!.window.MouseEvent("pointerdown", { bubbles: true, cancelable: true });
  act(() => {
    row.dispatchEvent(press);
  });
  expect(press.defaultPrevented).toBe(true);
  expect(doc.activeElement).toBe(field);
  act(() => row.click());
  expect(picks).toEqual(["a"]);
});

test("Return and Space on a focused row pick it, and no other key does", () => {
  const picks: string[] = [];
  const doc = mount(picks);
  const add = doc.querySelector<HTMLElement>('[role="button"]')!;
  for (const key of ["Enter", " ", "a"])
    act(() => {
      add.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  expect(picks).toEqual(["add", "add"]);
});

// `app.keyStyle` (keyStyle.ts): a list with `onListCommand` takes the keyboard under a key style
// (its field's leave focuses it) and runs the style's commands, Return as list.open; a command it
// declines goes on. In Standard it stays out of focus and every key passes, as before.
function drive(style: string, keys: StyleKey[] | "Enter") {
  const doc = installDom();
  const seen: ListCommand[] = [];
  act(() => configureKeyStyle({ "app.keyStyle": style }));
  act(() =>
    root!.render(
      <DrivenList
        kind="listbox"
        label="Model"
        onListCommand={(command) => {
          seen.push(command);
          return command !== "list.leave";
        }}
      >
        <DrivenRow id="row-a" kind="option" aria-selected onPick={() => {}}>
          Opus
        </DrivenRow>
      </DrivenList>,
    ),
  );
  const list = doc.querySelector<HTMLElement>('[role="listbox"]')!;
  const last =
    keys === "Enter"
      ? new dom!.window.KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true, cancelable: true })
      : pressStyleKeys(dom!.window, list, keys, (dispatch) => act(dispatch));
  if (keys === "Enter") act(() => void list.dispatchEvent(last!));
  return { seen, prevented: last?.defaultPrevented, tabIndex: list.getAttribute("tabindex") };
}

test("Vim: j, k, gg and G reach onListCommand from the list, which takes focus", () => {
  expect(drive("vim", ["j", "k", "g", "g", "G"])).toEqual({
    seen: ["list.next", "list.previous", "list.first", "list.last"],
    prevented: true,
    tabIndex: "-1",
  });
});

test("Emacs: Ctrl-N and Ctrl-P; Return on the list is list.open", () => {
  expect(drive("emacs", ["C-n", "C-p"]).seen).toEqual(["list.next", "list.previous"]);
  expect(drive("emacs", "Enter")).toMatchObject({ seen: ["list.open"], prevented: true });
});

test("a declined command goes on: Vim's Esc in the list reaches the popup", () => {
  expect(drive("vim", ["Escape"])).toMatchObject({ seen: ["list.leave"], prevented: false });
});

test("Standard: no focus stop, and j, Ctrl-N and Return pass untouched", () => {
  expect(drive("standard", ["j", "C-n"])).toEqual({ seen: [], prevented: false, tabIndex: null });
  expect(drive("standard", "Enter")).toMatchObject({ seen: [], prevented: false });
});
