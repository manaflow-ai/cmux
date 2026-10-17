// Panels as tabs on the right (Debug Settings agentChat.panelTabs, Lucas 2026-10-17): while panes show
// beside the chat, its tab strip is where new tabs go, so the header drops its quick-action buttons
// and "..." lists them all, Terminal and Browser first. Off, or with the chat alone, the header is
// as before.
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

test("with panelTabs and panes beside the chat, the buttons fold into the chat menu", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const runs: string[] = [];
  const render = (sideTabs: boolean) => {
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={(mode) => runs.push(`terminal:${mode}`)}
          onBrowser={(mode) => runs.push(`browser:${mode}`)}
          hasChanges
          onChanges={(mode) => runs.push(`changes:${mode}`)}
          onSideTabs={() => runs.push("newTab")}
          sideTabs={sideTabs}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
        />,
      ),
    );
  };
  configureQuickActions({});

  // Off: panes beside the chat leave the header as it was.
  render(true);
  expect(shown()).toEqual(["changes", "terminal", "browser"]);

  // On, with the chat alone: still the buttons.
  act(() => setHeaderState({ panelTabs: true }));
  render(false);
  expect(shown()).toEqual(["changes", "terminal", "browser"]);

  // On, with panes beside the chat: no buttons; "..." starts with every quick action.
  render(true);
  expect(shown()).toEqual([]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["Terminal", "Browser", "Changes", "Hide tabs", "Rename"]);
  const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover .acpmux-chat-menu-item")];
  await act(async () => rows()[0].click());
  expect(runs).toEqual(["terminal:toggle"]);

  act(() => setHeaderState({ panelTabs: false }));
  act(() => root?.unmount());
  root = undefined;
});
