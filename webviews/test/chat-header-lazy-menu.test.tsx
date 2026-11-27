// The chat header's "..." reads its rows as it opens, not on each pane render (goal chat-attach-p95).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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
] as const;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", ...windowKeys] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let doc: Document;

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
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const labels = () =>
  [...doc.querySelectorAll(".acpmux-chat-menu-popover .acpmux-chat-menu-item")].map(
    (row) => row.querySelector(".acpmux-chat-menu-label")?.textContent,
  );
const more = () => doc.querySelector<HTMLButtonElement>(".acpmux-header-more, [aria-label='Chat actions']");

test("a web header whose menu surely has rows builds none while the pane renders; opening reads them", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const { chatMenuHasRows } = await import("../src/agent-session/acpmux/pane/chatMenu");
  configureQuickActions({});
  let built = 0;
  root = createRoot(doc.getElementById("root")!);
  // Each pane render hands a new menu closure, as App.tsx's chatMenu is.
  const render = (rename: string) =>
    act(() =>
      root!.render(
        <ChatHeaderTools
          chat="s1"
          onTerminal={() => {}}
          onBrowser={() => {}}
          summary={null}
          menuHasRows={chatMenuHasRows(false, "s1")}
          menu={() => {
            built += 1;
            return [{ key: "rename", label: rename, icon: "folder", onSelect: () => {} }];
          }}
        />,
      ),
    );
  render("Rename");
  render("Rename");
  render("Rename again");
  expect(built).toBe(0);
  expect(more()?.disabled ?? false).toBe(false);
  // The rows are the newest pane render's, read as the menu opens.
  await act(async () => void openPicker("Chat actions"));
  expect(built).toBeGreaterThan(0);
  expect(labels()).toContain("Rename again");
  act(() => root?.unmount());
  root = undefined;
});

test("Quick Chat before its session may have no rows: the header reads them and draws its menu disabled", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { chatMenuHasRows } = await import("../src/agent-session/acpmux/pane/chatMenu");
  expect(chatMenuHasRows(true, undefined)).toBe(false);
  expect(chatMenuHasRows(true, "s1")).toBe(true);
  let built = 0;
  root = createRoot(doc.getElementById("root")!);
  act(() =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        tabTools={false}
        summary={null}
        menuHasRows={chatMenuHasRows(true, undefined)}
        menu={() => {
          built += 1;
          return [];
        }}
      />,
    ),
  );
  expect(built).toBeGreaterThan(0);
  expect(more()?.disabled).toBe(true);
  act(() => root?.unmount());
  root = undefined;
});
