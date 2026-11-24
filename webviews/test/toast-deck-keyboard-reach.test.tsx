// Keyboard reach through the agent pane's toast deck (#38090). A spread bottom deck is drawn newest
// at its foot and older toasts above it, so Shift-Tab, which moves up the screen, walks the newest
// toast's controls, then the older ones', and only then leaves the deck. Leaving, focus goes to the
// nearest earlier control a person can see: never an element with no box (no focus ring shows) and
// never a transcript row rendered past the viewport's edge (focusing it scrolls the reader away).
//
// The test document has no layout and no sequential focus navigation, so `press` plays the
// browser's part: it sends the key to the focused element and, unless the page took it, moves focus
// to the previous or next tabbable element in tree order. Boxes and hit testing are stubbed.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createNoticeQueue, NoticeStack } from "../src/ui/NoticeStack";
import { JumpToLatest } from "../src/agent-session/acpmux/VirtualTranscript";

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
  "PointerEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const VIEW = { width: 800, height: 600 };

/// A pane: transcript rows (one in view, one rendered below the viewport's edge), a control with no
/// box, then the toast deck, then the composer. With `disabledFieldsets`, a disabled fieldset whose
/// button is in view sits on each side of the deck: the browser never tabs to those buttons.
function renderPane({
  disabledFieldsets = false,
  jumpLatest = false,
}: { disabledFieldsets?: boolean; jumpLatest?: boolean } = {}): Document {
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
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.defineProperty(win, "innerWidth", { value: VIEW.width, configurable: true });
  Object.defineProperty(win, "innerHeight", { value: VIEW.height, configurable: true });
  const boxes: Record<string, { top: number; height: number }> = {
    "row-in-view": { top: 100, height: 24 },
    "row-below-view": { top: 1400, height: 24 },
    "no-box": { top: 0, height: 0 },
    "fieldset-above": { top: 300, height: 24 },
    "fieldset-below": { top: 560, height: 24 },
  };
  const proto = win.HTMLElement.prototype;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const box = boxes[this.id] ?? { top: 500, height: 40 };
    const width = box.height === 0 ? 0 : 120;
    return new win.DOMRect(40, box.top, width, box.height);
  };
  // Hit testing: what is drawn at a point inside the viewport.
  win.document.elementFromPoint = (x: number, y: number) => {
    if (x < 0 || y < 0 || x >= VIEW.width || y >= VIEW.height) return null;
    for (const element of win.document.querySelectorAll<HTMLElement>("button, textarea")) {
      const rect = element.getBoundingClientRect();
      if (rect.width > 0 && x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom) {
        if (element.closest(".ui-notice-deck")) continue;
        return element;
      }
    }
    return win.document.body;
  };
  const queue = createNoticeQueue();
  for (const message of ["First", "Second", "Third"]) queue.show({ message, duration: 0 });
  root = createRoot(win.document.getElementById("root")!);
  act(() =>
    root!.render(
      <>
        <section className="transcript">
          <button id="row-in-view" type="button">
            Copy Question 0
          </button>
          <button id="row-below-view" type="button">
            Copy Question 5
          </button>
        </section>
        <button id="no-box" type="button">
          Hidden
        </button>
        {disabledFieldsets ? (
          <fieldset disabled>
            <button id="fieldset-above" type="button">
              Retry
            </button>
          </fieldset>
        ) : null}
        {jumpLatest ? <JumpToLatest shown working={false} lift={0} onJump={() => {}} /> : null}
        <div className="dock">
          <NoticeStack queue={queue} dismissLabel="Dismiss" layout="stacked" />
          {disabledFieldsets ? (
            <fieldset disabled>
              <button id="fieldset-below" type="button">
                Attach
              </button>
            </fieldset>
          ) : null}
          <textarea id="composer" aria-label="Message" />
        </div>
      </>,
    ),
  );
  return win.document;
}

const TABBABLE = "button:not(:disabled), textarea:not(:disabled), input:not(:disabled), a[href], [tabindex]";

function tabbables(doc: Document): HTMLElement[] {
  return [...doc.querySelectorAll<HTMLElement>(TABBABLE)].filter(
    (element) => element.tabIndex >= 0 && !element.closest("[inert]"),
  );
}

/// Tab or Shift-Tab as the browser does it: the page may take the key; otherwise focus moves to the
/// next tabbable element in tree order.
function press(doc: Document, shift: boolean): void {
  const active = doc.activeElement as HTMLElement | null;
  if (!active) throw new Error("nothing focused");
  act(() => {
    const event = new dom!.window.KeyboardEvent("keydown", {
      key: "Tab",
      shiftKey: shift,
      bubbles: true,
      cancelable: true,
    });
    if (!active.dispatchEvent(event)) return;
    const order = tabbables(doc);
    const next = order[order.indexOf(active) + (shift ? -1 : 1)];
    next?.focus();
  });
}

/// The focused control's name: a toast's × by its toast's text, anything else by its id.
function focusedName(doc: Document): string {
  const active = doc.activeElement as HTMLElement | null;
  const card = active?.closest(".ui-notice-deck-card");
  if (card) return `${card.querySelector(".ui-notice-message, p")?.textContent ?? card.textContent} ×`;
  return active?.id || active?.getAttribute("aria-label") || active?.tagName || "none";
}

function focusFrontClose(doc: Document): void {
  const close = doc.querySelector<HTMLElement>('.ui-notice-deck-card[data-front] button[aria-label="Dismiss"]');
  if (!close) throw new Error("no front close button");
  act(() => close.focus());
}

test("Shift-Tab walks a spread deck from the newest toast to the oldest before it leaves", () => {
  const doc = renderPane();
  focusFrontClose(doc);
  const deck = doc.querySelector('.ui-notice-anchor[data-anchor="bottom"] > .ui-notice-deck')!;
  expect(deck.hasAttribute("data-expanded")).toBe(true);
  expect(focusedName(doc)).toBe("Third ×");
  const walked: string[] = [];
  for (let step = 0; step < 2; step += 1) {
    press(doc, true);
    walked.push(focusedName(doc));
  }
  expect(walked).toEqual(["Second ×", "First ×"]);
  // Still in the deck, so it stays spread.
  expect(deck.hasAttribute("data-expanded")).toBe(true);
});

test("Shift-Tab out of the deck lands on a control in view, never one with no box or past the viewport", () => {
  const doc = renderPane();
  focusFrontClose(doc);
  let left = "";
  for (let step = 0; step < 6 && !left; step += 1) {
    press(doc, true);
    if (!doc.activeElement?.closest(".ui-notice-deck")) left = focusedName(doc);
  }
  expect(left).toBe("row-in-view");
  expect(
    doc.querySelector('.ui-notice-anchor[data-anchor="bottom"] > .ui-notice-deck')!.hasAttribute("data-expanded"),
  ).toBe(false);
});

test("Tab from the newest toast goes on to the composer", () => {
  const doc = renderPane();
  focusFrontClose(doc);
  press(doc, false);
  expect(focusedName(doc)).toBe("composer");
});

test("leaving the deck skips buttons in a disabled fieldset, as the browser does", () => {
  const doc = renderPane({ disabledFieldsets: true });
  focusFrontClose(doc);
  const walked: string[] = [];
  for (let step = 0; step < 3; step += 1) {
    press(doc, true);
    walked.push(focusedName(doc));
  }
  // A disabled control can't take focus, so sending focus to one leaves it on the oldest toast.
  expect(walked).toEqual(["Second ×", "First ×", "row-in-view"]);

  focusFrontClose(doc);
  press(doc, false);
  expect(focusedName(doc)).toBe("composer");
});

// Jump to latest floats over the transcript's foot, just before the deck in the document, so it is
// where Shift-Tab out of the deck lands in the agent pane. It is a layer over the transcript too:
// the browser's next stop before it is a row the virtual list rendered past the viewport's edge,
// and focusing that row scrolled the reader away (#38090, real-app capture after #38126).
test("Shift-Tab from the deck through Jump to latest stays on controls in view", () => {
  const doc = renderPane({ jumpLatest: true });
  focusFrontClose(doc);
  const walked: string[] = [];
  for (let step = 0; step < 4; step += 1) {
    press(doc, true);
    walked.push(focusedName(doc));
  }
  expect(walked).toEqual(["Second ×", "First ×", "Jump to latest", "row-in-view"]);
});
