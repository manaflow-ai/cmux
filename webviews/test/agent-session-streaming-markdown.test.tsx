import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { TranscriptTurn } from "../src/agent-session/react/main";
import type { TranscriptEntry } from "../src/agent-session/shared/sessionModel";

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, unknown>();
for (const key of [
  "window",
  "document",
  "navigator",
  "Element",
  "Node",
  "HTMLElement",
  "HTMLStyleElement",
  "customElements",
]) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as Record<string, unknown>)[key];
    } else {
      (globalThis as Record<string, unknown>)[key] = value;
    }
  }
});

function setupDom(): JSDOM {
  const nextDom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/agent",
  });
  const globals = globalThis as Record<string, unknown>;
  globals.window = nextDom.window;
  globals.document = nextDom.window.document;
  globals.navigator = nextDom.window.navigator;
  globals.Element = nextDom.window.Element;
  globals.Node = nextDom.window.Node;
  globals.HTMLElement = nextDom.window.HTMLElement;
  globals.HTMLStyleElement = nextDom.window.HTMLStyleElement;
  globals.customElements = nextDom.window.customElements;
  // Minimal markdown engine so renderMarkdownHTML exercises the markdown path
  // instead of the plain-text fallback (which would mask streaming markdown).
  (nextDom.window as unknown as { marked: unknown }).marked = {
    parse: (source: string) => source.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>"),
  };
  return nextDom;
}

function renderTurn(entry: TranscriptEntry): void {
  const container = dom?.window.document.getElementById("root");
  expect(container).toBeTruthy();
  root = createRoot(container!);
  flushSync(() => {
    root?.render(React.createElement(TranscriptTurn, { entry }));
  });
}

test("streaming assistant turn renders markdown live instead of raw text", () => {
  dom = setupDom();
  renderTurn({ id: "a1", role: "assistant", text: "**bold**", isComplete: false });
  const bubble = dom.window.document.querySelector(".codex-assistant-message");
  expect(bubble).toBeTruthy();
  expect(bubble?.innerHTML).toContain("<strong>bold</strong>");
  expect(bubble?.textContent).not.toContain("**");
});

test("completed assistant turn still renders markdown", () => {
  dom = setupDom();
  renderTurn({ id: "a2", role: "assistant", text: "**done**", isComplete: true });
  const bubble = dom.window.document.querySelector(".codex-assistant-message");
  expect(bubble?.innerHTML).toContain("<strong>done</strong>");
});
