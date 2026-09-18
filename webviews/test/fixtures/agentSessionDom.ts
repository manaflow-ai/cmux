import { expect } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";

export function installDomGlobals(dom: JSDOM): () => void {
  const originalWindow = (globalThis as any).window;
  const originalDocument = (globalThis as any).document;
  const originalNavigator = (globalThis as any).navigator;
  const originalHistory = (globalThis as any).history;
  const originalElement = (globalThis as any).Element;
  const originalEvent = (globalThis as any).Event;
  const originalInputEvent = (globalThis as any).InputEvent;
  const originalMouseEvent = (globalThis as any).MouseEvent;
  const originalNode = (globalThis as any).Node;
  const originalHTMLElement = (globalThis as any).HTMLElement;
  const originalAttachEvent = (dom.window.HTMLElement.prototype as any).attachEvent;
  const originalGetSelection = (globalThis as any).getSelection;
  const originalGetComputedStyle = (globalThis as any).getComputedStyle;
  const originalInnerHeight = (globalThis as any).innerHeight;
  const originalScrollTo = (globalThis as any).scrollTo;
  const originalWebkit = (globalThis as any).webkit;

  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).navigator = dom.window.navigator;
  (globalThis as any).history = dom.window.history;
  (globalThis as any).Element = dom.window.Element;
  (globalThis as any).Event = dom.window.Event;
  (globalThis as any).InputEvent = dom.window.InputEvent;
  (globalThis as any).MouseEvent = dom.window.MouseEvent;
  (globalThis as any).Node = dom.window.Node;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  // React's legacy input polyfill probes attachEvent when it sees a jsdom
  // document. WKWebView implements the API, so keep the test DOM compatible
  // with the runtime without emitting a spurious event-dispatch exception.
  if (!(dom.window.HTMLElement.prototype as any).attachEvent) {
    (dom.window.HTMLElement.prototype as any).attachEvent = () => {};
  }
  (globalThis as any).getSelection = dom.window.getSelection.bind(dom.window);
  (globalThis as any).getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  (globalThis as any).innerHeight = 800;
  (globalThis as any).scrollTo = () => {};
  dom.window.scrollTo = () => {};

  return () => {
    restoreGlobal("window", originalWindow);
    restoreGlobal("document", originalDocument);
    restoreGlobal("navigator", originalNavigator);
    restoreGlobal("history", originalHistory);
    restoreGlobal("Element", originalElement);
    restoreGlobal("Event", originalEvent);
    restoreGlobal("InputEvent", originalInputEvent);
    restoreGlobal("MouseEvent", originalMouseEvent);
    restoreGlobal("Node", originalNode);
    restoreGlobal("HTMLElement", originalHTMLElement);
    if (originalAttachEvent === undefined) {
      delete (dom.window.HTMLElement.prototype as any).attachEvent;
    } else {
      (dom.window.HTMLElement.prototype as any).attachEvent = originalAttachEvent;
    }
    restoreGlobal("getSelection", originalGetSelection);
    restoreGlobal("getComputedStyle", originalGetComputedStyle);
    restoreGlobal("innerHeight", originalInnerHeight);
    restoreGlobal("scrollTo", originalScrollTo);
    restoreGlobal("webkit", originalWebkit);
  };
}

export function pasteIntoPromptEditor(dom: JSDOM, text: string): void {
  installEditorGeometryShim(dom);
  const editor = dom.window.document.querySelector(".ProseMirror") as HTMLElement;
  expect(editor).toBeTruthy();
  editor.focus();
  const pasteEvent = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(pasteEvent, "clipboardData", {
    value: {
      getData: (type: string) => (type === "text/plain" || type === "Text" ? text : ""),
      types: ["text/plain"],
    },
  });
  editor.dispatchEvent(pasteEvent);
}

function installEditorGeometryShim(dom: JSDOM): void {
  const rect = {
    bottom: 0,
    height: 0,
    left: 0,
    right: 0,
    top: 0,
    width: 0,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  };
  const list = {
    0: rect,
    length: 1,
    item: (index: number) => (index === 0 ? rect : null),
    [Symbol.iterator]: function* () {
      yield rect;
    },
  };
  for (const prototype of [dom.window.Text.prototype, dom.window.Element.prototype, dom.window.Range.prototype]) {
    if (!("getClientRects" in prototype)) {
      Object.defineProperty(prototype, "getClientRects", {
        configurable: true,
        value: () => list,
      });
    }
    if (!("getBoundingClientRect" in prototype)) {
      Object.defineProperty(prototype, "getBoundingClientRect", {
        configurable: true,
        value: () => rect,
      });
    }
  }
}

export async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    flushSync(() => {});
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("Timed out waiting for GUI mode render.");
}

function restoreGlobal(name: string, value: unknown): void {
  if (value === undefined) {
    delete (globalThis as any)[name];
  } else {
    (globalThis as any)[name] = value;
  }
}
