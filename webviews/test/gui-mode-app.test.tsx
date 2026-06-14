import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { GuiModeApp } from "../src/gui-mode/GuiModeApp";
import { submitGuiModePrompt } from "../src/gui-mode/bridge";

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
    expect(Array.from(dom.window.document.querySelectorAll(".gui-mode-provider-option"))
      .map((element) => element.textContent)).toEqual([
        "CodexNative cmux session",
        "Claude CodeNative cmux session",
        "OpenCodeNative cmux session",
        "GrokHook-backed terminal",
        "PiPlugin-backed terminal",
        "OMPPlugin-backed terminal",
        "AmpPlugin-backed terminal",
        "CursorPlugin-backed terminal",
        "GeminiHook-backed terminal",
        "KiroHook-backed terminal",
        "AntigravityHook-backed terminal",
        "Rovo DevHook-backed terminal",
        "Hermes AgentHook-backed terminal",
        "CopilotHook-backed terminal",
        "CodeBuddyHook-backed terminal",
        "FactoryHook-backed terminal",
      ]);
  } finally {
    flushSync(() => root.unmount());
    await new Promise((resolve) => setTimeout(resolve, 0));
    restoreGlobals();
    dom.window.close();
  }
});

test("GUI mode submit sends the selected provider to native", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "file:///tmp/gui-mode.html",
  });
  const postedMessages: unknown[] = [];
  const restoreGlobals = installDomGlobals(dom);
  (dom.window as any).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: unknown) => {
          postedMessages.push(message);
          return Promise.resolve({ ok: true, value: { workspaceId: "workspace-1" } });
        },
      },
    },
  };

  try {
    await expect(submitGuiModePrompt("build the GUI", "gemini")).resolves.toEqual({ workspaceId: "workspace-1" });
    expect(postedMessages).toHaveLength(1);
    expect(postedMessages[0]).toMatchObject({
      method: "guiMode.submit",
      params: {
        prompt: "build the GUI",
        providerId: "gemini",
      },
    });
  } finally {
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
  const originalWebkit = (globalThis as any).webkit;

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
    restoreGlobal("webkit", originalWebkit);
  };
}

function restoreGlobal(name: string, value: unknown): void {
  if (value === undefined) {
    delete (globalThis as any)[name];
  } else {
    (globalThis as any)[name] = value;
  }
}
