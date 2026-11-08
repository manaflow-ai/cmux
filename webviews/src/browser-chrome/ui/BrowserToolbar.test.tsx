// The toolbar row's native parity (the AppKit toolbar it replaced, at e873e31e8669): long-press
// Back and Forward for history, right-click menus on the profile and machine badges, the badges'
// tooltips, the focus mode badge's glyph and help, the dimmer hollow star, accessibility ids and
// extension values, and the chip's drag image.
import { afterEach, expect, jest, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { BrowserToolbar, extensionLabel, HOLD_MENU_MS, setChipDragImage } from "./BrowserToolbar";
import { resolveChip, type BrowserToolbarCommand, type OmnibarBadges } from "./toolbarModel";

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
  "PointerEvent",
  "getComputedStyle",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];

function install(): JSDOM {
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
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom;
}

function render(node: ReactNode): Document {
  const win = install().window;
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  jest.useRealTimers();
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function toolbar(
  sent: BrowserToolbarCommand[],
  badges: OmnibarBadges = {},
  bookmark: "off" | "on" = "off",
  holdsFieldFocus = false,
) {
  return (
    <BrowserToolbar
      navigation={{ canGoBack: true, canGoForward: true, loading: false }}
      omnibar={{ text: "example.com", chip: resolveChip(null), bookmark }}
      extensions={{ shows: true, pinned: [{ id: "abc", name: "Reader", label: "Reader Mode", value: "3" }] }}
      onCommand={(command) => sent.push(command)}
      width={1200}
      badges={badges}
      holdsFieldFocus={holdsFieldFocus}
    />
  );
}

const press = (element: Element, type: string, init: MouseEventInit = {}) =>
  act(() => {
    element.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, ...init }));
  });

test("a press on Back held past the hold time opens its history, and the release presses nothing", async () => {
  const sent: BrowserToolbarCommand[] = [];
  const doc = render(toolbar(sent));
  const back = doc.querySelector('[data-toolbar-button="back"]')!;
  jest.useFakeTimers();
  press(back, "pointerdown");
  await act(async () => void jest.advanceTimersByTime(HOLD_MENU_MS));
  press(back, "pointerup");
  press(back, "click");
  expect(sent).toEqual([{ type: "navigationMenu", direction: "back" }]);
  // A quick press goes back, and opens no menu.
  sent.length = 0;
  press(back, "pointerdown");
  press(back, "pointerup");
  press(back, "click");
  await act(async () => void jest.advanceTimersByTime(HOLD_MENU_MS));
  expect(sent).toEqual([{ type: "goBack" }]);
});

test("the profile and machine badges open their menus on a right-click too, with their help as tooltip", () => {
  const sent: BrowserToolbarCommand[] = [];
  const doc = render(
    toolbar(sent, {
      profile: { monogram: "W", name: "Work", help: "Browser profile: Work" },
      machine: { text: "devbox", help: "localhost is devbox" },
      focusMode: { text: "Focus Mode", help: "Press Esc twice to leave" },
    }),
  );
  const profile = doc.getElementById("cmux.browser.profileBadge")!;
  expect(profile.getAttribute("title")).toBe("Browser profile: Work");
  expect(profile.getAttribute("aria-label")).toBe("Browser profile: Work");
  press(profile, "contextmenu");
  const machine = doc.querySelector('[data-rect="badge:machine"]')!;
  expect(machine.getAttribute("aria-label")).toBe("localhost is devbox");
  expect(machine.querySelector(".bc-badge-label")?.textContent).toBe("devbox");
  press(machine, "contextmenu");
  expect(sent).toEqual([{ type: "profileBadge" }, { type: "machineBadge" }]);
  const focus = doc.getElementById("cmux.browser.focusModeBadge")!;
  expect(focus.getAttribute("title")).toBe("Press Esc twice to leave");
  expect(focus.querySelector('[data-icon="keyboard"]')).not.toBeNull();
});

test("controls carry the native accessibility identifiers; the hollow star is marked off", () => {
  const doc = render(toolbar([], {}, "off"));
  expect(doc.getElementById("cmux.browser.bookmarkStar")?.hasAttribute("data-on")).toBe(false);
  expect(doc.getElementById("browser.extensions.button")).not.toBeNull();
  const action = doc.getElementById("browser.extension.action.abc")!;
  expect(action.getAttribute("aria-label")).toBe("Reader Mode, 3");
  expect(action.getAttribute("title")).toBe("Reader");
});

test("an extension's spoken label is its name, then its badge", () => {
  expect(extensionLabel({ id: "a", name: "Title", label: "Name", value: "12" })).toBe("Name, 12");
  expect(extensionLabel({ id: "a", name: "Title" })).toBe("Title");
  expect(extensionLabel({ id: "a", name: "Title", badge: { text: "4" } })).toBe("Title, 4");
});

test("a page dragged out of the chip shows its title, else its URL, as the drag image", () => {
  const win = install().window;
  const images: { text: string | null; x: number }[] = [];
  const transfer = {
    setDragImage: (element: Element, x: number) => images.push({ text: element.textContent, x }),
  } as unknown as DataTransfer;
  setChipDragImage(transfer, { url: "https://example.com/a", title: "Example Page" });
  setChipDragImage(transfer, { url: "https://example.com/b", title: "  " });
  expect(images).toEqual([
    { text: "Example Page", x: 8 },
    { text: "https://example.com/b", x: 8 },
  ]);
  expect(win.document.querySelectorAll(".bc-drag-label").length).toBe(2);
});

test("while the field edits, a press on a pinned extension leaves the keys in the field", () => {
  const sent: BrowserToolbarCommand[] = [];
  const doc = render(toolbar(sent, {}, "off", true));
  const action = doc.getElementById("browser.extension.action.abc")!;
  const mouseDown = () => {
    const down = new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
    act(() => {
      action.dispatchEvent(down);
    });
    return down.defaultPrevented;
  };
  // At rest the press goes through, so a drag can reorder the extension.
  expect(mouseDown()).toBe(false);
  // While the field has the keys, the press keeps them there.
  const field = doc.createElement("input");
  doc.body.append(field);
  field.focus();
  expect(mouseDown()).toBe(true);
  press(action, "click");
  expect(sent).toEqual([{ type: "extensionAction", id: "abc" }]);
});

test("Back, Forward and Reload keep their native accessibility identifiers", () => {
  const doc = render(toolbar([]));
  for (const id of ["browser.toolbar.back", "browser.toolbar.forward", "browser.toolbar.reload"]) {
    expect(doc.getElementById(id)).not.toBeNull();
  }
});

test("a row that cannot reload draws Reload off (the Markdown tab's empty state)", () => {
  const doc = render(
    <BrowserToolbar
      navigation={{ canGoBack: false, canGoForward: false, loading: false, canReload: false }}
      omnibar={{ text: "", chip: resolveChip(null), bookmark: "hidden" }}
      onCommand={() => {}}
      width={800}
    />,
  );
  expect(doc.getElementById("browser.toolbar.reload")?.hasAttribute("disabled")).toBe(true);
});

test("Chromium's drawing of an extension button draws alone; the letter fallback draws its badge", () => {
  const doc = render(
    <BrowserToolbar
      navigation={{ canGoBack: true, canGoForward: true, loading: false }}
      omnibar={{ text: "example.com", chip: resolveChip(null), bookmark: "off" }}
      extensions={{
        shows: true,
        pinned: [
          { id: "drawn", name: "Drawn", iconUrl: "data:image/png;base64,AA==", badge: { text: "3" } },
          { id: "letter", name: "Letter", badge: { text: "4" } },
        ],
      }}
      onCommand={() => {}}
      width={1200}
    />,
  );
  const drawn = doc.getElementById("browser.extension.action.drawn")!;
  expect(drawn.querySelector("img.bc-extension-icon")).not.toBeNull();
  expect(drawn.querySelector(".bc-extension-badge")).toBeNull();
  const letter = doc.getElementById("browser.extension.action.letter")!;
  expect(letter.querySelector(".bc-extension-initial")?.textContent).toBe("L");
  expect(letter.querySelector(".bc-extension-badge")?.textContent).toBe("4");
});

function standaloneRow(showsButtons: boolean): Document {
  return render(
    <BrowserToolbar
      navigation={{ canGoBack: true, canGoForward: true, loading: false }}
      omnibar={{ text: "example.com", chip: resolveChip(null), bookmark: "off" }}
      extensions={{ shows: false, pinned: [] }}
      onCommand={() => {}}
      width={600}
      showsButtons={showsButtons}
      resolvedButtons={[]}
    />,
  );
}

/** The control groups after the bar that draw something. */
const followingGroups = (doc: Document) =>
  Array.from(doc.querySelectorAll(".bc-omnibar ~ .bc-group")).filter((group) => group.childElementCount > 0);

const DROPS_BAR_MARGIN = ".bc-omnibar:not(:has(~ .bc-group:not(:empty))) {\n  margin-inline-end: 0;";

test("a popup window's row (no buttons) has nothing after the bar, so the bar keeps no margin", () => {
  expect(followingGroups(standaloneRow(false))).toEqual([]);
  expect(readFileSync(new URL("./browserChrome.css", import.meta.url), "utf8")).toContain(DROPS_BAR_MARGIN);
});

test("a Markdown tab's row (navigation only) has nothing after the bar either", () => {
  const doc = standaloneRow(true);
  expect(followingGroups(doc)).toEqual([]);
  expect(doc.querySelector(".bc-trailing")?.childNodes.length).toBe(0);
});

test("while the row holds the field's focus, its chip and buttons stay in the Tab order", () => {
  const doc = render(toolbar([], {}, "off", true));
  const controls = Array.from(doc.querySelectorAll<HTMLElement>(".bc-toolbar button"));
  expect(controls.length).toBeGreaterThan(3);
  for (const control of controls) expect(control.tabIndex).toBe(0);
  // A press still keeps the field's focus: the mouse never moves it.
  const back = doc.getElementById("browser.toolbar.back")!;
  const down = new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
  act(() => {
    back.dispatchEvent(down);
  });
  expect(down.defaultPrevented).toBe(true);
});
