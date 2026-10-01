import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import "../../Resources/markdown-viewer/viewer-navigation.js";

let dom: JSDOM | null = null;

afterEach(() => {
  dom?.window.close();
  dom = null;
});

test("viewer navigation shares smooth Vim and Emacs motions", () => {
  dom = new JSDOM("<!doctype html><html><body><div id='viewer'></div></body></html>");
  const viewer = dom.window.document.getElementById("viewer") as HTMLElement;
  Object.defineProperties(viewer, {
    clientHeight: { value: 600 },
    scrollHeight: { value: 2_400 },
  });
  const calls: Array<["to", ScrollToOptions]> = [];
  viewer.scrollTo = ((options: ScrollToOptions) => { calls.push(["to", options]); }) as typeof viewer.scrollTo;

  const dispose = CmuxViewerNavigation.install({
    target: dom.window.document,
    getScroller: () => viewer,
    shortcuts: {
      diffViewerScrollDown: shortcut("j"),
      diffViewerScrollUp: shortcut("k"),
      diffViewerScrollHalfPageDown: shortcut("d", { control: true }),
      diffViewerScrollHalfPageUp: shortcut("u", { control: true }),
      diffViewerScrollDownEmacs: shortcut("n", { control: true }),
      diffViewerScrollUpEmacs: shortcut("p", { control: true }),
      diffViewerScrollToBottom: shortcut("g", { shift: true }),
      diffViewerScrollToTop: chord("g", "g"),
    },
  });

  dispatchKey("j");
  viewer.scrollTop = 600;
  dom.window.document.dispatchEvent(new dom.window.WheelEvent("wheel", { bubbles: true }));
  dispatchKey("j");
  dispatchKey("d", { ctrlKey: true });
  dispatchKey("p", { ctrlKey: true });
  dispatchKey("G", { shiftKey: true });
  dispatchKey("g");
  dispatchKey("g");

  expect(calls).toEqual([
    ["to", { top: 72, behavior: "smooth" }],
    ["to", { top: 672, behavior: "smooth" }],
    ["to", { top: 972, behavior: "smooth" }],
    ["to", { top: 900, behavior: "smooth" }],
    ["to", { top: 1_800, behavior: "smooth" }],
    ["to", { top: 0, behavior: "smooth" }],
  ]);
  dispose();

  function dispatchKey(key: string, init: KeyboardEventInit = {}) {
    dom?.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key, ...init }));
  }
});

test("viewer navigation leaves editable controls and unbound shortcuts alone", () => {
  dom = new JSDOM("<!doctype html><html><body><div id='viewer'></div><textarea id='editor'></textarea></body></html>");
  const viewer = dom.window.document.getElementById("viewer") as HTMLElement;
  let scrollCount = 0;
  viewer.scrollTo = () => { scrollCount += 1; };
  const dispose = CmuxViewerNavigation.install({
    target: dom.window.document,
    getScroller: () => viewer,
    shortcuts: {
      diffViewerScrollDown: shortcut("j"),
      diffViewerScrollHalfPageDown: { unbound: true },
    },
  });

  const editor = dom.window.document.getElementById("editor")!;
  editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "j" }));
  dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "d", ctrlKey: true }));

  expect(scrollCount).toBe(0);
  dispose();
});

test("direct viewer actions reset their smooth target after manual input", () => {
  dom = new JSDOM("<!doctype html><html><body><div id='viewer'></div></body></html>");
  const viewer = dom.window.document.getElementById("viewer") as HTMLElement;
  Object.defineProperties(viewer, {
    clientHeight: { value: 600 },
    scrollHeight: { value: 2_400 },
  });
  const tops: number[] = [];
  viewer.scrollTo = ((options: ScrollToOptions) => { tops.push(Number(options.top)); }) as typeof viewer.scrollTo;
  const dispose = CmuxViewerNavigation.installManualInputReset({
    target: dom.window.document,
    getScroller: () => viewer,
  });

  CmuxViewerNavigation.performAction("diffViewerScrollDown", viewer);
  viewer.scrollTop = 600;
  dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "PageDown" }));
  CmuxViewerNavigation.performAction("diffViewerScrollDown", viewer);
  viewer.scrollTop = 900;
  dom.window.document.dispatchEvent(new dom.window.WheelEvent("wheel", { bubbles: true }));
  CmuxViewerNavigation.performAction("diffViewerScrollDown", viewer);

  expect(tops).toEqual([72, 672, 972]);
  dispose();
});

test("programmatic jumps can reset a pending smooth target", () => {
  dom = new JSDOM("<!doctype html><html><body><div id='viewer'></div></body></html>");
  const viewer = dom.window.document.getElementById("viewer") as HTMLElement;
  Object.defineProperties(viewer, {
    clientHeight: { value: 600 },
    scrollHeight: { value: 2_400 },
  });
  const tops: number[] = [];
  viewer.scrollTo = ((options: ScrollToOptions) => { tops.push(Number(options.top)); }) as typeof viewer.scrollTo;

  CmuxViewerNavigation.performAction("diffViewerScrollDown", viewer);
  viewer.scrollTop = 1_000;
  CmuxViewerNavigation.resetSmoothTarget(viewer);
  CmuxViewerNavigation.performAction("diffViewerScrollDown", viewer);

  expect(tops).toEqual([72, 1_072]);
});

function shortcut(key: string, modifiers: Record<string, boolean> = {}) {
  return { first: { key, command: false, control: false, option: false, shift: false, ...modifiers } };
}

function chord(first: string, second: string) {
  return { first: shortcut(first).first, second: shortcut(second).first };
}
