// Header tools fold instead of being cut off in a narrow pane (header/headerOverflow.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
// Base UI's menus read these window globals.
const windowKeys = [
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
] as const;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", ...windowKeys] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let doc: Document;
let paneWidth = 1000;
const observers = new Set<{ fire(): void }>();

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const source = window as unknown as Record<string, unknown>;
  for (const key of windowKeys)
    scope[key] =
      typeof source[key] === "function" && !/^[A-Z]/.test(key) ? (source[key] as Function).bind(window) : source[key];
  doc = window.document;
  // jsdom lays nothing out: the header is `paneWidth` wide, each tool button its 24px plus the 2px gap.
  scope.ResizeObserver = class {
    constructor(private readonly callback: (entries: unknown[]) => void) {
      observers.add(this);
    }
    observe() {}
    disconnect() {
      observers.delete(this);
    }
    fire() {
      this.callback([]);
    }
  };
  Object.defineProperty(window.HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-header") ? paneWidth : 0;
    },
  });
  window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const width = this.classList.contains("acpmux-header") ? paneWidth : this.querySelectorAll("button").length * 26;
    return { width, height: 24, x: 0, y: 0, top: 0, left: 0, right: width, bottom: 24, toJSON: () => ({}) } as DOMRect;
  };
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const labels = () =>
  [...doc.querySelectorAll(".acpmux-chat-menu-popover .acpmux-chat-menu-item")].map(
    (row) => row.querySelector(".acpmux-chat-menu-label")?.textContent,
  );
const shown = () =>
  [...doc.querySelectorAll(".acpmux-header-tools [data-quick-action]")].map((button) =>
    button.getAttribute("data-quick-action"),
  );

// Leo 2026-10-24: "pay attention to the top icons. they're cut off here ... things dont get cut off,
// things look proper when you have multiple tabs". A pane too narrow for the header's buttons folds
// the trailing ones into "..." (still there, still running their split) instead of cutting them off
// at the pane's edge; widening the pane brings them back.
test("the fold count covers the overflow by whole buttons and does not depend on what is folded", async () => {
  const { headerFoldCount, HEADER_TOOL_PITCH } = await import("../src/agent-session/acpmux/header/headerOverflow");
  expect(headerFoldCount(200, 0, 300, 4)).toBe(0);
  expect(headerFoldCount(200, 0, 199, 4)).toBe(1);
  expect(headerFoldCount(200, 0, 200 - HEADER_TOOL_PITCH - 1, 4)).toBe(2);
  // The same full width measured with one already folded gives the same answer.
  expect(headerFoldCount(200 - HEADER_TOOL_PITCH, 1, 199, 4)).toBe(1);
  expect(headerFoldCount(200, 0, 0, 4)).toBe(4);
  expect(headerFoldCount(200, 0, 0, 0)).toBe(0);
});

test("a narrow pane folds the trailing header buttons into the chat menu and a wide one shows them again", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const runs: string[] = [];
  configureQuickActions({ quickActions: ["terminal", "browser", "splitDown"] });
  paneWidth = 1000;
  root = createRoot(doc.getElementById("root")!);
  act(() =>
    root!.render(
      <header className="acpmux-header">
        <div className="acpmux-handoff-header-tools">
          <ChatHeaderTools
            onTerminal={(mode) => runs.push(`terminal:${mode}`)}
            onSplitDown={(mode) => runs.push(`splitDown:${mode}`)}
            onBrowser={(mode) => runs.push(`browser:${mode}`)}
            summary={null}
            menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
          />
        </div>
      </header>,
    ),
  );
  const resize = (width: number) => {
    paneWidth = width;
    // Each observer measures again, as the header's and the tools' resizes would make it.
    for (let pass = 0; pass < 3; pass++) act(() => observers.forEach((observer) => observer.fire()));
  };
  expect(shown()).toEqual(["terminal", "browser", "splitDown"]);

  // Room for the leading reserve, "..." and two of the three buttons.
  resize(120 + 4 * 26 - 1);
  expect(shown()).toEqual(["terminal", "browser"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()[0]).toBe("Split Down");
  expect(labels()).toContain("Rename");
  const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover .acpmux-chat-menu-item")];
  await act(async () => rows()[0].click());
  expect(runs).toEqual(["splitDown:toggle"]);

  // Narrower still: every button folds, "..." stays.
  resize(120 + 26);
  expect(shown()).toEqual([]);
  expect(doc.querySelector(".acpmux-header-tools [aria-label='Chat actions']")).not.toBeNull();
  await act(async () => void openPicker("Chat actions"));
  expect(labels().slice(0, 3)).toEqual(["Terminal", "Browser", "Split Down"]);

  // Wide again: the buttons are back and "..." no longer lists them.
  resize(1000);
  expect(shown()).toEqual(["terminal", "browser", "splitDown"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).not.toContain("Split Down");
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});
