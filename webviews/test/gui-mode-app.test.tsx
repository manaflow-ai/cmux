import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { GuiModeApp } from "../src/gui-mode/GuiModeApp";

test("GUI mode renders the composer while native context is pending", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "file:///tmp/gui-mode.html",
  });
  const restoreGlobals = installDomGlobals(dom);
  (dom.window as any).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: () => new Promise(() => {}),
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);

  try {
    flushSync(() => {
      root.render(<GuiModeApp />);
    });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(dom.window.document.querySelector(".gui-mode-home")).toBeTruthy();
    expect(dom.window.document.querySelector(".gui-mode-editor")).toBeTruthy();
    expect(dom.window.document.querySelector(".gui-mode-submit")?.textContent).toBe("Submit");
  } finally {
    flushSync(() => root.unmount());
    await new Promise((resolve) => setTimeout(resolve, 0));
    restoreGlobals();
    dom.window.close();
  }
});

function installDomGlobals(dom: JSDOM): () => void {
  const originalWindow = (globalThis as any).window;
  const originalDocument = (globalThis as any).document;
  const originalNavigator = (globalThis as any).navigator;
  const originalElement = (globalThis as any).Element;
  const originalNode = (globalThis as any).Node;
  const originalHTMLElement = (globalThis as any).HTMLElement;
  const originalGetSelection = (globalThis as any).getSelection;
  const originalInnerHeight = (globalThis as any).innerHeight;
  const originalScrollTo = (globalThis as any).scrollTo;

  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).navigator = dom.window.navigator;
  (globalThis as any).Element = dom.window.Element;
  (globalThis as any).Node = dom.window.Node;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).getSelection = dom.window.getSelection.bind(dom.window);
  (globalThis as any).innerHeight = 800;
  (globalThis as any).scrollTo = () => {};
  dom.window.scrollTo = () => {};

  return () => {
    restoreGlobal("window", originalWindow);
    restoreGlobal("document", originalDocument);
    restoreGlobal("navigator", originalNavigator);
    restoreGlobal("Element", originalElement);
    restoreGlobal("Node", originalNode);
    restoreGlobal("HTMLElement", originalHTMLElement);
    restoreGlobal("getSelection", originalGetSelection);
    restoreGlobal("innerHeight", originalInnerHeight);
    restoreGlobal("scrollTo", originalScrollTo);
  };
}

function restoreGlobal(name: string, value: unknown): void {
  if (value === undefined) {
    delete (globalThis as any)[name];
  } else {
    (globalThis as any)[name] = value;
  }
}
