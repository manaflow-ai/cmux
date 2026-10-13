// The chat header keeps the most-used tools visible (Leo 2026-10-12: about four buttons, not
// everything in menus): Terminal, Browser and [+] New tab, then Sources and "...". Split Down, Changes,
// Preview and Files fold into the top of "...", each while it applies, and run with the toggle mode as
// their buttons did. A quick action the person shows in the header (layout.json) leaves "..." again.
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

test("the header shows Terminal, Browser and New tab; Split Down, Changes and Preview fold into the chat menu", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const runs: string[] = [];
  const render = () => {
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={(mode) => runs.push(`terminal:${mode}`)}
          onSplitDown={(mode) => runs.push(`splitDown:${mode}`)}
          onBrowser={(mode) => runs.push(`browser:${mode}`)}
          hasChanges
          onChanges={(mode) => runs.push(`changes:${mode}`)}
          previewUrl="http://localhost:5173/"
          onPreview={(url, mode) => runs.push(`preview:${url}:${mode}`)}
          onSideTabs={() => runs.push("newTab")}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
        />,
      ),
    );
  };

  configureQuickActions({});
  render();
  expect(shown()).toEqual(["terminal", "browser", "newTab"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["Split Down", "Changes", "Preview", "Rename"]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  expect(runs).toEqual(["splitDown:toggle"]);

  // Shown in the header again: its button is back and "..." no longer lists it.
  act(() => configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "newTab"] }));
  render();
  expect(shown()).toEqual(["terminal", "splitDown", "browser", "newTab"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["Changes", "Preview", "Rename"]);
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});
