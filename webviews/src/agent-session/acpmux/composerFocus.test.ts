import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import React from "react";
import { shouldBlurComposerOnPress, useComposerKeyboard } from "./composerFocus";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function fixture() {
  dom = new JSDOM(
    '<!doctype html><html><body><main class="transcript"><div class="acpmux-composer-box"><div contenteditable="true"><span>draft</span></div></div><button class="transcript-action">Open</button></main></body></html>',
  );
  const document = dom.window.document;
  return {
    composer: document.querySelector(".acpmux-composer-box")!,
    editor: document.querySelector("[contenteditable]")!,
    outside: document.querySelector(".transcript")!,
    button: document.querySelector(".transcript-action")!,
  };
}

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

function ComposerFocusHarness() {
  useComposerKeyboard(() => true);
  return React.createElement(
    "main",
    null,
    React.createElement(
      "div",
      { className: "acpmux-composer-box" },
      React.createElement("div", { contentEditable: true, tabIndex: 0 }),
    ),
    React.createElement("div", { className: "transcript" }, "reply"),
  );
}

describe("composer click-away focus", () => {
  test("a transcript press blurs a focused composer", () => {
    const { editor, outside } = fixture();
    expect(shouldBlurComposerOnPress(outside, editor)).toBe(true);
  });

  test("a press inside the composer keeps its editor focus", () => {
    const { composer, editor } = fixture();
    expect(shouldBlurComposerOnPress(composer, editor)).toBe(false);
    expect(shouldBlurComposerOnPress(editor.firstChild, editor)).toBe(false);
  });

  test("a control outside the composer also releases focus", () => {
    const { button, editor } = fixture();
    expect(shouldBlurComposerOnPress(button, editor)).toBe(true);
  });

  test("a non-composer focus does not trigger a second blur", () => {
    const { button } = fixture();
    expect(shouldBlurComposerOnPress(button, button)).toBe(false);
  });

  test("the capture listener blurs the editor when a transcript row is pressed", async () => {
    const container = installDom();
    await act(async () => {
      root = createRoot(container);
      root.render(React.createElement(ComposerFocusHarness));
    });
    const editor = container.querySelector<HTMLElement>("[contenteditable]")!;
    const transcript = container.querySelector<HTMLElement>(".transcript")!;
    editor.focus();
    expect(dom!.window.document.activeElement).toBe(editor);
    await act(async () => {
      transcript.dispatchEvent(new dom!.window.Event("pointerdown", { bubbles: true }));
    });
    expect(dom!.window.document.activeElement).not.toBe(editor);
  });

  test("window focus loss also releases the composer editor", async () => {
    const container = installDom();
    await act(async () => {
      root = createRoot(container);
      root.render(React.createElement(ComposerFocusHarness));
    });
    const editor = container.querySelector<HTMLElement>("[contenteditable]")!;
    editor.focus();
    await act(async () => {
      dom!.window.dispatchEvent(new dom!.window.Event("blur"));
    });
    expect(dom!.window.document.activeElement).not.toBe(editor);
  });
});
