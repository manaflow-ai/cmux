// View Only (cmux NEXT watch): an All chats row's menu opens a Claude Code or Codex chat in a tab that
// shows it without running it (`chats.watch`); a chat acpmux cannot watch has the item off.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  window.HTMLElement.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, toJSON() {} }) as DOMRect;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a Claude Code or Codex row's menu offers View Only and names the chat", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList, watchable } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  expect(["claude-code:a", "codex:b"].every(watchable)).toBe(true);
  expect(["opencode:a", "claude-code:", "pi:x"].some(watchable)).toBe(false);
  const load = async () => ({
    chats: [
      { key: "claude-code:a", harness: "claude-code", title: "Fix the build", cwd: "/tmp/cmux", updatedAt: 2 },
      { key: "opencode:b", harness: "opencode", title: "Write docs", cwd: "/tmp/cmux", updatedAt: 1 },
    ],
    ready: true,
  });
  const viewed: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(<AllChatsList load={load} onOpen={() => {}} onViewOnly={(key) => viewed.push(key)} />),
  );
  await act(async () => {});
  const row = (title: string) =>
    [...host.querySelectorAll<HTMLElement>("button")].find((button) => button.textContent?.includes(title))!;
  const viewOnly = () =>
    [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === "View Only");

  const window = scope.window as Window & typeof globalThis;
  await act(async () => {
    row("Write docs").dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 5, clientY: 5 }));
  });
  expect(viewOnly()?.hasAttribute("disabled")).toBe(true);
  await act(async () => {
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await act(async () => {
    row("Fix the build").dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 5, clientY: 5 }));
  });
  const item = viewOnly();
  expect(item).toBeDefined();
  await act(async () => item!.click());
  expect(viewed).toEqual(["claude-code:a"]);
});
