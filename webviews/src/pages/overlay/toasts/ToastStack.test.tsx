// The toast stack draws what the app sends and sends the person's clicks back (ToastStack.tsx).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { ToastStack } from "./ToastStack";
import type { ToastRect, ToastState } from "./types";

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
  "PointerEvent",
  "getComputedStyle",
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
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const words = {
  t: (key: string) => `<${key}>`,
  format: (key: string, ...args: string[]) => `<${key}:${args.join(",")}>`,
};
const toast = (serial: number, more: Partial<ToastState> = {}): ToastState => ({
  serial,
  id: `t${serial}`,
  message: `message ${serial}`,
  closable: true,
  showsDetails: false,
  showsUndoKey: false,
  ...more,
});
const details = { title: "Details", isUndo: false, revealsDetails: true };
const undo = { title: "Undo", isUndo: true, revealsDetails: false };

function stack(toasts: ToastState[], log: string[] = [], layouts: ToastRect[][] = []) {
  return (
    <ToastStack
      toasts={toasts}
      floor={16}
      words={words}
      onAction={(serial) => log.push(`action ${serial}`)}
      onClose={(serial) => log.push(`close ${serial}`)}
      onHover={(serial, hovered) => log.push(`hover ${serial} ${hovered}`)}
      onLayout={(rects) => layouts.push(rects)}
    />
  );
}

test("the toasts draw oldest first, newest at the bottom, and say where they are", () => {
  const layouts: ToastRect[][] = [];
  const doc = render(stack([toast(1), toast(2), toast(3)], [], layouts));
  const drawn = [...doc.querySelectorAll<HTMLElement>(".cmux-toast")].map((element) => element.dataset.toastSerial);
  expect(drawn).toEqual(["1", "2", "3"]);
  expect(layouts.at(-1)?.map((rect) => rect.serial)).toEqual([1, 2, 3]);
  expect(doc.querySelector<HTMLElement>(".cmux-toasts")?.style.bottom).toBe("16px");
});

test("the action and close go back to the app with the toast's serial", () => {
  const log: string[] = [];
  const doc = render(stack([toast(7, { action: undo, showsUndoKey: true })], log));
  act(() => doc.querySelector<HTMLButtonElement>(".cmux-toast-action")!.click());
  act(() => doc.querySelector<HTMLButtonElement>(".cmux-toast-close")!.click());
  expect(log).toEqual(["action 7", "close 7"]);
  // Only the Undo Cmd-Z runs says the key.
  expect(doc.querySelector(".cmux-toast-action")?.getAttribute("aria-keyshortcuts")).toBe("Meta+Z");
  expect(doc.querySelector(".cmux-toast-close")?.getAttribute("aria-label")).toBe("<overlay.toasts.dismiss>");
});

test("Details off keeps the reason in the tooltip; on, it shows in plain words with the code under it", () => {
  const detail = "cannot copy: fs.no_space: no space left";
  const closed = render(stack([toast(1, { action: details, detail })]));
  expect(closed.querySelector(".cmux-toast-detail")).toBeNull();
  expect(closed.querySelector(".cmux-toast-message")?.getAttribute("title")).toBe(detail);
  expect(closed.querySelector(".cmux-toast-action")?.textContent).toBe("Details");
  act(() => root?.render(stack([toast(1, { action: details, detail, showsDetails: true })])));
  const open = closed;
  expect(open.querySelector(".cmux-toast-detail-text")?.textContent).toBe("<overlay.toasts.detail.noSpace>");
  expect(open.querySelector(".cmux-toast-detail-code")?.textContent).toBe(
    "<overlay.toasts.detail.errorCode:fs.no_space>",
  );
  expect(open.querySelector(".cmux-toast-action")?.textContent).toBe("<overlay.toasts.hideDetails>");
  expect(open.querySelector(".cmux-toast-action")?.getAttribute("aria-expanded")).toBe("true");
});

test("a toast that ends leaves the stack at once when motion is off", () => {
  const doc = render(stack([toast(1), toast(2)]));
  act(() => root?.render(stack([toast(2)])));
  expect([...doc.querySelectorAll<HTMLElement>(".cmux-toast")].map((element) => element.dataset.toastSerial)).toEqual([
    "2",
  ]);
});

// Review 1 of #37289 (F1): a removed toast reported no toasts and no fading copy before its copy drew,
// so the host took the page off the overlay at once and the fade never showed. The stack reports the
// fading copy while it fades, then nothing once it is gone.
test("a closed toast is reported fading until its fade ends", () => {
  const fades: { onfinish: (() => void) | null }[] = [];
  const reports: [number, number][] = [];
  const view = (toasts: ToastState[]) => (
    <ToastStack
      toasts={toasts}
      floor={16}
      words={words}
      onAction={() => {}}
      onClose={() => {}}
      onHover={() => {}}
      onLayout={(rects, fading) => reports.push([rects.length, fading.length])}
    />
  );
  const doc = render(view([toast(1)]));
  doc.documentElement.dataset.cmuxMotion = "reduced";
  (dom!.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function () {
    const animation = { onfinish: null as (() => void) | null, oncancel: null, cancel() {} };
    fades.push(animation);
    return animation;
  };
  expect(reports.at(-1)).toEqual([1, 0]);
  act(() => root!.render(view([])));
  expect(reports).not.toContainEqual([0, 0]);
  expect(reports.at(-1)).toEqual([0, 1]);
  act(() => fades.at(-1)?.onfinish?.());
  expect(reports.at(-1)).toEqual([0, 0]);
});

// Review 2 of #37289 (F1): a message of several lines (Home's stop-all notice) ran into one line; the
// native label kept its line breaks.
test("a toast message keeps its line breaks", () => {
  const css = readFileSync(new URL("./toasts.css", import.meta.url), "utf8");
  const rule = css.match(/\.cmux-toast-message \{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toContain("white-space: pre-wrap;");
});

// Review 3 of #37289 (F1): on the overlay page the toast's own glass could not blur the window under the
// panel, so terminal text read sharp through it. There the app draws the glass; the toast paints none.
test("on the app's glass a toast paints no glass of its own", () => {
  const doc = render(
    <ToastStack
      toasts={[toast(1)]}
      floor={16}
      words={words}
      onAction={() => {}}
      onClose={() => {}}
      onHover={() => {}}
      onLayout={() => {}}
      nativeGlass
    />,
  );
  const shown = doc.querySelector(".cmux-toast")!;
  expect(shown.classList.contains("ui-glass")).toBe(false);
  expect(shown.getAttribute("data-native-glass")).toBe("true");
});

// Review 4 of #37289: the motion read each toast's place after React had laid it out anew, so a toast a
// newer one pushed up snapped there instead of sliding, while its native glass slid.
test("a toast pushed up by a newer one slides from where it was", () => {
  const tops = new Map<string, number>([["1", 100]]);
  const slides: { serial: string | undefined; first: unknown }[] = [];
  const view = (toasts: ToastState[]) => stack(toasts);
  const doc = render(view([toast(1)]));
  const proto = dom!.window.HTMLElement.prototype as unknown as {
    animate: unknown;
    getBoundingClientRect: () => DOMRect;
  };
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const top = tops.get(this.dataset.toastSerial ?? "") ?? 0;
    return { x: 0, y: top, top, left: 0, right: 300, bottom: top + 40, width: 300, height: 40, toJSON() {} } as DOMRect;
  };
  proto.animate = function (this: HTMLElement, frames: Keyframe[]) {
    slides.push({ serial: this.dataset.toastSerial, first: frames[0]?.transform });
    return { onfinish: null, oncancel: null, cancel() {} };
  };
  // Lay toast 1 out at 100 (its place), then a newer toast takes 100 and pushes it up to 52.
  act(() => root!.render(view([toast(1, { message: "again" })])));
  tops.set("1", 52);
  tops.set("2", 100);
  act(() => root!.render(view([toast(1, { message: "again" }), toast(2)])));
  expect(doc.querySelectorAll(".cmux-toast").length).toBe(2);
  expect(slides).toContainEqual({ serial: "1", first: "translate(0.00px, 48.00px)" });
});

// Review 5 of #37289 (F2): the fading copy's place was set from the stack's origin read while the copy
// still sat in the bottom-anchored flow; once the copy left the flow the stack's top moved down by the
// copy's height, and the copy with it. The origin is read with the copy out of the flow.
test("a closed toast fades where it was", () => {
  const view = (toasts: ToastState[]) => stack(toasts);
  const doc = render(view([toast(1)]));
  doc.documentElement.dataset.cmuxMotion = "reduced";
  const proto = dom!.window.HTMLElement.prototype as unknown as {
    animate: unknown;
    getBoundingClientRect: () => DOMRect;
  };
  const box = (top: number, height: number) =>
    ({ x: 0, y: top, top, left: 0, right: 300, bottom: top + height, width: 300, height, toJSON() {} }) as DOMRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    if (this.classList.contains("cmux-toasts")) {
      // Bottom-anchored at 340: a toast in the flow raises its top by 40.
      const inFlow = [...this.querySelectorAll<HTMLElement>("[data-toast-serial]")].filter(
        (element) => element.style.position !== "absolute",
      );
      return box(340 - 40 * inFlow.length, 40 * inFlow.length);
    }
    return box(300, 40);
  };
  proto.animate = () => ({ onfinish: null, oncancel: null, cancel() {} });
  act(() => root!.render(view([toast(1, { message: "again" })])));
  act(() => root!.render(view([])));
  const copy = doc.querySelector<HTMLElement>("[data-toast-exiting]");
  expect(copy?.style.top).toBe("-40px");
});

// CMUX-359: the fading copy kept only its width. In a stack taller than the room a toast's Details give
// up height (toasts.css), and out of the flow the copy grew back to its full Details while it faded.
// The copy keeps the height it had in the stack.
test("a closed toast fades at the size it had", () => {
  const view = (toasts: ToastState[]) => stack(toasts);
  const doc = render(view([toast(1)]));
  doc.documentElement.dataset.cmuxMotion = "reduced";
  const proto = dom!.window.HTMLElement.prototype as unknown as {
    animate: unknown;
    getBoundingClientRect: () => DOMRect;
  };
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const height = this.classList.contains("cmux-toasts") ? 400 : 64;
    return {
      x: 0,
      y: 300,
      top: 300,
      left: 0,
      right: 300,
      bottom: 300 + height,
      width: 300,
      height,
      toJSON() {},
    } as DOMRect;
  };
  proto.animate = () => ({ onfinish: null, oncancel: null, cancel() {} });
  act(() => root!.render(view([toast(1, { message: "again" })])));
  act(() => root!.render(view([])));
  const copy = doc.querySelector<HTMLElement>("[data-toast-exiting]");
  expect(copy?.style.width).toBe("300px");
  expect(copy?.style.height).toBe("64px");
});

// Review 6 of #37289 (F1): the stack was anchored only at its floor, so long Details on several toasts in
// a short window pushed the older toasts' buttons above the page, where it clips them. The stack spans
// the page above its floor with its toasts at the bottom, and a toast that does not fit gives up the
// height of its Details (which scroll), never its title row and buttons. The toast's own minimum is its
// title row (review of #37289 at a3f8a3de, F1: a 0 minimum let a collapsed toast shrink under its
// buttons); test/overlay-toast-rows-hold-browser.test.ts checks the laid-out bounds in Chromium.
test("every toast's buttons stay on the page however tall the stack is", () => {
  const css = readFileSync(new URL("./toasts.css", import.meta.url), "utf8");
  const rule = (selector: string) => css.match(new RegExp(`(?:^|\\n)${selector} \\{([^}]*)\\}`))?.[1] ?? "";
  expect(rule("\\.cmux-toasts")).toContain("top: 0;");
  // At the bottom through a spacer that shrinks to nothing, never `flex-end`, which pushed toasts
  // that did not fit above the page (review of #37289 at 74444fd5, F1; the browser test checks it).
  expect(rule("\\.cmux-toasts")).not.toContain("justify-content: flex-end;");
  expect(rule("\\.cmux-toasts::before")).toContain("flex: 1 0 0;");
  expect(rule("\\.cmux-toast")).toContain("grid-template-rows: auto minmax(0, 1fr);");
  expect(rule("\\.cmux-toast")).not.toContain("min-height: 0;");
  expect(rule("\\.cmux-toast-detail")).toContain("min-height: 0;");
});
