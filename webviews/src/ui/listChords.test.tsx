// Ctrl-N and Ctrl-P step every composer menu and picker as Down and Up do, and Return runs the row
// they reached. Lawrence, 2026-10-28 (via Leo): "leo this needs to work with keyboard shortcuts like
// up arrow ctrl n/p etc" and "clicking enter doesnt work". The shared Menu (Base UI: the + menu, the
// model, mode and send menus) owns its arrows, so the chord plays as the arrow it stands for.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Menu, MenuButton, MenuItem, MenuPopup } from "./Menu";
import { listChordArrow, listStep } from "./listChords";
import { settleReact } from "../../test/support/domTeardown";

test("the chord table: Ctrl-N is Down, Ctrl-P is Up, nothing else is", () => {
  expect(listChordArrow({ key: "n", ctrlKey: true })).toBe("ArrowDown");
  expect(listChordArrow({ key: "p", ctrlKey: true })).toBe("ArrowUp");
  expect(listChordArrow({ key: "N", ctrlKey: true })).toBe("ArrowDown");
  expect(listChordArrow({ key: "n" })).toBeUndefined();
  expect(listChordArrow({ key: "n", ctrlKey: true, metaKey: true })).toBeUndefined();
  expect(listChordArrow({ key: "p", ctrlKey: true, shiftKey: true })).toBeUndefined();
  expect(listStep({ key: "ArrowDown" })).toBe(1);
  expect(listStep({ key: "ArrowUp" })).toBe(-1);
  expect(listStep({ key: "ArrowDown", shiftKey: true })).toBe(0);
  expect(listStep({ key: "n", ctrlKey: true })).toBe(1);
  expect(listStep({ key: "p", ctrlKey: true })).toBe(-1);
});

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
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const tick = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

function TestMenu({ onRun }: { onRun: (name: string) => void }) {
  return (
    <Menu>
      <MenuButton label="Actions">Actions</MenuButton>
      <MenuPopup label="Actions">
        <MenuItem onSelect={() => onRun("copy")}>Copy</MenuItem>
        <MenuItem onSelect={() => onRun("rename")}>Rename</MenuItem>
        <MenuItem onSelect={() => onRun("delete")}>Delete</MenuItem>
      </MenuPopup>
    </Menu>
  );
}

const trigger = (doc: Document) => doc.querySelector<HTMLElement>('button[aria-label="Actions"]')!;
const highlighted = (doc: Document) =>
  doc.querySelector('[role="menuitem"][data-highlighted]')?.textContent ??
  (doc.activeElement?.getAttribute("role") === "menuitem" ? doc.activeElement.textContent : undefined);

async function open(doc: Document) {
  trigger(doc).focus();
  await act(async () => {
    trigger(doc).click();
  });
  await tick();
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("true");
}

async function press(doc: Document, init: KeyboardEventInit) {
  const target = (doc.activeElement as HTMLElement | null) ?? doc.body;
  await act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });
  await tick();
}

test("the shared menu: Ctrl-N and Ctrl-P walk the rows the arrows walk, and Return runs the one reached", async () => {
  // What the arrows reach, the reference.
  const arrowed: (string | undefined)[] = [];
  {
    const doc = render(<TestMenu onRun={() => {}} />);
    await open(doc);
    await press(doc, { key: "ArrowDown" });
    arrowed.push(highlighted(doc));
    await press(doc, { key: "ArrowDown" });
    arrowed.push(highlighted(doc));
    await press(doc, { key: "ArrowUp" });
    arrowed.push(highlighted(doc));
    await act(async () => root!.unmount());
    root = undefined;
  }
  expect(arrowed.every((name) => name !== undefined)).toBe(true);
  expect(new Set(arrowed).size).toBeGreaterThan(1);

  const ran: string[] = [];
  const doc = render(<TestMenu onRun={(name) => ran.push(name)} />);
  await open(doc);
  const chorded: (string | undefined)[] = [];
  await press(doc, { key: "n", ctrlKey: true });
  chorded.push(highlighted(doc));
  await press(doc, { key: "n", ctrlKey: true });
  chorded.push(highlighted(doc));
  await press(doc, { key: "p", ctrlKey: true });
  chorded.push(highlighted(doc));
  expect(chorded).toEqual(arrowed);
  await press(doc, { key: "Enter" });
  expect(ran).toEqual([arrowed[2]!.toLowerCase()]);
});
