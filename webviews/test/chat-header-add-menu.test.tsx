// The [+] header designs (header/headerStyle.ts, layout.json `headerStyle`, Lucas 2026-10-17): `add`
// puts one [+] in place of the quick-action buttons, listing every tab the chat can open beside it;
// `add-terminal` keeps Terminal's button; `tray` and `labels` lay every tab out in one group. Terminal and Browser add another on every pick. "..." no
// longer lists those tabs. Unset, the header is as before.
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

test("[+] lists the tabs the chat opens beside it, each pick adding one", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { configureHeaderStyle } = await import("../src/agent-session/acpmux/header/headerStyle");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const runs: string[] = [];
  const render = () => {
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={(mode) => runs.push(`terminal:${mode}`)}
          onBrowser={(mode) => runs.push(`browser:${mode}`)}
          onSplitDown={(mode) => runs.push(`splitDown:${mode}`)}
          hasChanges
          onChanges={(mode) => runs.push(`changes:${mode}`)}
          onSideTabs={() => runs.push("newTab")}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
        />,
      ),
    );
  };
  configureQuickActions({});

  configureHeaderStyle({});
  render();
  expect(shown()).toEqual(["changes", "terminal", "browser"]);

  act(() => configureHeaderStyle({ headerStyle: "add" }));
  render();
  expect(shown()).toEqual([]);
  await act(async () => void openPicker("New tab"));
  expect(labels()).toEqual(["Terminal", "Browser", "Changes", "Split Down"]);
  const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover .acpmux-chat-menu-item")];
  await act(async () => rows()[0].click());
  expect(runs).toEqual(["terminal:open"]);

  // "..." keeps New tab and the chat's own rows, not the tabs [+] lists.
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["New tab", "Rename"]);

  act(() => configureHeaderStyle({ headerStyle: "add-terminal" }));
  render();
  expect(shown()).toEqual(["terminal"]);
  await act(async () => void openPicker("New tab"));
  expect(labels()).toEqual(["Browser", "Changes", "Split Down"]);

  act(() => configureHeaderStyle({}));
  act(() => root?.unmount());
  root = undefined;
});

test("tray and labels show every tab the chat opens beside it, in one group", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureHeaderStyle } = await import("../src/agent-session/acpmux/header/headerStyle");
  const runs: string[] = [];
  const render = () => {
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={(mode) => runs.push(`terminal:${mode}`)}
          onBrowser={(mode) => runs.push(`browser:${mode}`)}
          onSplitDown={(mode) => runs.push(`splitDown:${mode}`)}
          onFiles={(mode) => runs.push(`files:${mode}`)}
          hasChanges
          onChanges={(mode) => runs.push(`changes:${mode}`)}
          summary={null}
          menu={() => []}
        />,
      ),
    );
  };
  for (const style of ["tray", "labels", "quiet", "expand"]) {
    act(() => configureHeaderStyle({ headerStyle: style }));
    render();
    expect(shown()).toEqual(["terminal", "browser", "changes", "files"]);
    expect(doc.querySelectorAll(".acpmux-header-tray__label").length).toBe(
      style === "labels" || style === "expand" ? 4 : 0,
    );
  }
  const button = (id: string) => doc.querySelector<HTMLElement>(`.acpmux-header-tray [data-quick-action="${id}"]`)!;
  act(() => button("terminal").click());
  act(() => button("changes").click());
  expect(runs).toEqual(["terminal:open", "changes:toggle"]);
  act(() => configureHeaderStyle({}));
  act(() => root?.unmount());
  root = undefined;
});
