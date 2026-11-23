// Press-drag-release on the shared Menu (Lawrence via Leo, 2026-11-17: "mousedown mouseup interaction
// not working here", "so he click and hold on the context menu start and then it goes over and then
// release should go"). A press on a menu button opens the menu; dragging onto a row and releasing
// runs that row and closes the menu; a plain click opens it and leaves it open. When the App draws
// the menu (a native popup), the release belongs to the App's panel: the page neither picks a page
// row under it nor closes the menu on that release.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Menu, MenuButton, MenuItem, MenuPopup } from "./Menu";
import { UiProvider } from "./UiProvider";
import type { PopupHost } from "./popupHost";
import type { NativePopupTransport } from "./nativePopup";
import { PRESS_CLICK_MS } from "./pressRelease";
import { settleReact } from "../../test/support/domTeardown";

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

/** One macrotask, inside act: React commits what the last event set. */
const tick = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

/** A press held past the click time: pressRelease.ts reads Date.now(), so the hold is wall-clock time. */
const holdPastClick = () =>
  act(async () => {
    // fixed-wait: the press must outlast PRESS_CLICK_MS on the wall clock (pressRelease.ts uses Date.now())
    await new Promise((resolve) => setTimeout(resolve, PRESS_CLICK_MS + 20));
  });

/** A mouse pointer event as WebKit sends it (jsdom has no PointerEvent). */
function pointer(target: EventTarget, type: string, x: number, y: number) {
  const View = (target as Node).ownerDocument?.defaultView ?? dom!.window;
  const event = new View.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y });
  Object.defineProperties(event, { pointerId: { value: 1 }, pointerType: { value: "mouse" } });
  act(() => {
    target.dispatchEvent(event);
  });
}

function mouse(target: EventTarget, type: string, x: number, y: number, detail = 1) {
  const event = new dom!.window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: x,
    clientY: y,
    detail,
  });
  act(() => {
    target.dispatchEvent(event);
  });
}

/** What is under the pointer: jsdom does no layout, so the test says. */
function under(doc: Document, pick: () => Element | null) {
  (doc as Document & { elementFromPoint(x: number, y: number): Element | null }).elementFromPoint = () => pick();
}

function TestMenu({ onRun }: { onRun: (name: string) => void }) {
  return (
    <Menu>
      <MenuButton label="Actions">Actions</MenuButton>
      <MenuPopup label="Actions">
        <MenuItem onSelect={() => onRun("copy")}>Copy</MenuItem>
        <MenuItem onSelect={() => onRun("rename")}>Rename</MenuItem>
      </MenuPopup>
    </Menu>
  );
}

const trigger = (doc: Document) => doc.querySelector<HTMLElement>('button[aria-label="Actions"]')!;
const row = (doc: Document, name: string) =>
  [...doc.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === name) ?? null;

test("press on the menu button, drag onto a row, release: the row runs and the menu closes", async () => {
  const ran: string[] = [];
  const doc = render(<TestMenu onRun={(name) => ran.push(name)} />);
  under(doc, () => trigger(doc));
  pointer(trigger(doc), "pointerdown", 10, 10);
  mouse(trigger(doc), "mousedown", 10, 10);
  await tick();
  const rename = row(doc, "Rename");
  expect(rename).not.toBeNull();
  // The press drags down onto Rename and lets go there, as on a Mac menu.
  under(doc, () => row(doc, "Rename"));
  pointer(rename!, "pointermove", 12, 40);
  pointer(rename!, "pointermove", 14, 60);
  pointer(rename!, "pointerup", 14, 60);
  await tick();
  expect(ran).toEqual(["rename"]);
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("false");
});

test("a held press released on a row without moving picks it too (past the click time)", async () => {
  const ran: string[] = [];
  const doc = render(<TestMenu onRun={(name) => ran.push(name)} />);
  under(doc, () => trigger(doc));
  pointer(trigger(doc), "pointerdown", 10, 10);
  mouse(trigger(doc), "mousedown", 10, 10);
  // fixed-wait: a held press (holdPastClick)
  await holdPastClick();
  under(doc, () => row(doc, "Copy"));
  pointer(row(doc, "Copy")!, "pointerup", 10, 10);
  await tick();
  expect(ran).toEqual(["copy"]);
});

test("a plain click opens the menu and leaves it open; a later click on a row runs it", async () => {
  const ran: string[] = [];
  const doc = render(<TestMenu onRun={(name) => ran.push(name)} />);
  under(doc, () => trigger(doc));
  pointer(trigger(doc), "pointerdown", 10, 10);
  mouse(trigger(doc), "mousedown", 10, 10);
  pointer(trigger(doc), "pointerup", 10, 10);
  mouse(trigger(doc), "mouseup", 10, 10);
  mouse(trigger(doc), "click", 10, 10);
  await tick();
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("true");
  expect(row(doc, "Copy")).not.toBeNull();
  expect(ran).toEqual([]);
  row(doc, "Copy")!.click();
  await tick();
  expect(ran).toEqual(["copy"]);
});

test("a press dragged away and released off any row closes the menu and runs nothing", async () => {
  const ran: string[] = [];
  const doc = render(<TestMenu onRun={(name) => ran.push(name)} />);
  under(doc, () => trigger(doc));
  pointer(trigger(doc), "pointerdown", 10, 10);
  mouse(trigger(doc), "mousedown", 10, 10);
  // fixed-wait: a held press (holdPastClick)
  await holdPastClick();
  under(doc, () => doc.body);
  pointer(doc.body, "pointermove", 300, 300);
  pointer(doc.body, "pointerup", 300, 300);
  await tick();
  expect(ran).toEqual([]);
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("false");
});

test("an App-drawn menu leaves the release to the App: no page row under it runs, the menu stays", async () => {
  const shown: unknown[] = [];
  const transport: NativePopupTransport = {
    show: async (model) => {
      shown.push(model);
      return { shown: true };
    },
    update: () => {},
    hide: () => {},
    listen: () => () => {},
  };
  const host: PopupHost = {
    native: transport,
    show: async () => ({ shown: true }),
    update: () => {},
    hide: () => {},
    owner: () => null,
    listen: () => () => {},
  };
  const pageRows: string[] = [];
  const doc = render(
    <UiProvider container={null} popupHost={host}>
      <Menu
        native={{
          model: { side: "bottom", align: "start", width: 200, rows: [{ id: "copy", kind: "action", label: "Copy" }] },
          onEvent: () => {},
        }}
      >
        <MenuButton label="Actions">Actions</MenuButton>
        <MenuPopup label="Actions">
          <MenuItem onSelect={() => {}}>Copy</MenuItem>
        </MenuPopup>
      </Menu>
      {/* A page list row that happens to lie under the App's panel. */}
      {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/prefer-tag-over-role, jsx-a11y/interactive-supports-focus -- a bare page row fixture: the test clicks it through the panel */}
      <div role="option" aria-selected="false" onClick={() => pageRows.push("clicked")}>
        Page row
      </div>
    </UiProvider>,
  );
  const pageRow = doc.querySelector<HTMLElement>('[role="option"]')!;
  under(doc, () => trigger(doc));
  pointer(trigger(doc), "pointerdown", 10, 10);
  mouse(trigger(doc), "mousedown", 10, 10);
  // fixed-wait: a held press (holdPastClick)
  await holdPastClick();
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("true");
  under(doc, () => pageRow);
  pointer(doc.body, "pointermove", 20, 60);
  pointer(doc.body, "pointerup", 20, 60);
  await tick();
  expect(pageRows).toEqual([]);
  expect(trigger(doc).getAttribute("aria-expanded")).toBe("true");
  expect(shown.length).toBeGreaterThan(0);
});
