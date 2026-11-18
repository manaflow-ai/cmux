// After the app's hung-renderer watchdog ends a chat's renderer, the chat that reloads says so in
// a line of its own pane, in its first frame (no row popping in later): the app's new-document
// script sets the flag before the pane's module runs (PageWebView+Liveness.swift restartFlagScript).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { RendererRestartNotice } from "./RendererRestartNotice";
import {
  RENDERER_RESTART_CHANGED,
  RENDERER_RESTART_GLOBAL,
  bootRendererRestart,
  dismissRendererRestart,
  readRendererRestart,
} from "./rendererRestartStore";
import { settleReact } from "../../../test/support/domTeardown";

const LINE = "This chat stopped responding, so cmux restarted it.";
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dismissRendererRestart();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// The pane's boot: the module reads the flag, then React draws the pane's first frame. flushSync
/// returns after the commit and its layout effects (the notice slot's claim), before any paint:
/// the row read there is the first frame's.
function bootAndPaint(container: HTMLElement): Element | null {
  let firstFrame: Element | null = null;
  act(() => {
    bootRendererRestart();
    root = createRoot(container);
    flushSync(() =>
      root!.render(
        <NoticeSlot>
          <RendererRestartNotice />
        </NoticeSlot>,
      ),
    );
    firstFrame = container.querySelector("[data-renderer-restart]");
  });
  return firstFrame;
}

test("a page booted with the restart flag draws the line in its first frame", () => {
  const container = installDom();
  scope[RENDERER_RESTART_GLOBAL] = { line: LINE };
  const firstFrame = bootAndPaint(container);
  expect(firstFrame?.querySelector("span")?.textContent).toBe(LINE);
});

test("a page booted without the flag draws no line", () => {
  const container = installDom();
  delete scope[RENDERER_RESTART_GLOBAL];
  expect(bootAndPaint(container)).toBeNull();
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
});

test("Dismiss takes the line away for the rest of the document", async () => {
  const container = installDom();
  scope[RENDERER_RESTART_GLOBAL] = { line: LINE };
  bootAndPaint(container);
  const button = container.querySelector<HTMLButtonElement>("[data-renderer-restart] button")!;
  await act(async () => button.click());
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
  bootRendererRestart();
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
});

// Architect review of #46474 (F2): Dismiss cleared only the global, so the app's script coming late
// (it sets the global again and calls the hook) brought back a line the person had dismissed.
test("a dismissed line stays hidden when the app's script comes late", async () => {
  const container = installDom();
  scope[RENDERER_RESTART_GLOBAL] = { line: LINE };
  bootAndPaint(container);
  const button = container.querySelector<HTMLButtonElement>("[data-renderer-restart] button")!;
  await act(async () => button.click());
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
  scope[RENDERER_RESTART_GLOBAL] = { line: LINE };
  await act(async () => (scope[RENDERER_RESTART_CHANGED] as () => void)());
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
  await act(async () => bootRendererRestart());
  expect(container.querySelector("[data-renderer-restart]")).toBeNull();
});

test("a flag that comes after the pane started still draws the line", async () => {
  const container = installDom();
  delete scope[RENDERER_RESTART_GLOBAL];
  bootAndPaint(container);
  scope[RENDERER_RESTART_GLOBAL] = { line: LINE };
  await act(async () => (scope[RENDERER_RESTART_CHANGED] as () => void)());
  expect(container.querySelector("[data-renderer-restart] span")?.textContent).toBe(LINE);
});

test("a malformed flag is no line", () => {
  expect(readRendererRestart(undefined)).toBeUndefined();
  expect(readRendererRestart({ line: "" })).toBeUndefined();
  expect(readRendererRestart({ line: 3 })).toBeUndefined();
  expect(readRendererRestart({ line: LINE })).toBe(LINE);
});
