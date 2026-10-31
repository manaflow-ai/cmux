// The chat header keeps the most-used tools visible (Leo 2026-10-12: about four buttons, not
// everything in menus): Changes (while the chat has changes), Terminal and Browser (which opens the
// chat's page, Leo 2026-10-20), then Sources and "...". [+] New tab, Files and Split Down fold into the top of "...", and
// run with the toggle mode as their buttons did. A quick action the person shows in the header
// (layout.json) leaves "..." again, except Changes: while the chat has changes, "..." lists it too, as
// the Codex and Claude apps' chat menus do (hq#2569 item 4).
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

test("the header shows Changes, Terminal and Browser; New tab, Files and Split Down fold into the chat menu", async () => {
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
          onFiles={(mode) => runs.push(`files:${mode}`)}
          onSideTabs={() => runs.push("newTab")}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
        />,
      ),
    );
  };

  configureQuickActions({});
  render();
  expect(shown()).toEqual(["changes", "terminal", "browser"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["Changes", "New tab", "Files", "Split Down", "Rename"]);
  const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover .acpmux-chat-menu-item")];
  await act(async () => rows()[3].click());
  expect(runs).toEqual(["splitDown:toggle"]);
  await act(async () => void openPicker("Chat actions"));
  await act(async () => rows()[0].click());
  expect(runs).toEqual(["splitDown:toggle", "changes:toggle"]);

  // Shown in the header again: its button is back and "..." no longer lists it.
  act(() => configureQuickActions({ quickActions: ["changes", "terminal", "browser", "splitDown"] }));
  render();
  expect(shown()).toEqual(["changes", "terminal", "browser", "splitDown"]);
  await act(async () => void openPicker("Chat actions"));
  expect(labels()).toEqual(["Changes", "New tab", "Files", "Rename"]);
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});

test("a hidden Changes or Preview folds into the chat menu while it applies; the rows read the state as the menu opens", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const runs: string[] = [];
  const render = (props: { hasChanges?: boolean; sideTabs?: boolean; tabTools?: boolean; refresh?: string[] }) => {
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={() => {}}
          hasChanges={props.hasChanges}
          onChanges={(mode) => runs.push(`changes:${mode}`)}
          onPreview={(url, mode) => runs.push(`preview:${url}:${mode}`)}
          sideTabs={props.sideTabs}
          onSideTabs={() => runs.push("newTab")}
          tabTools={props.tabTools}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "folder", onSelect: () => runs.push("rename") }]}
          // The App's tab state refresh as "..." opens (pane.tabState).
          onMenuOpen={async () => props.refresh && setHeaderState({ lit: props.refresh })}
        />,
      ),
    );
  };
  const open = async () => {
    await act(async () => void openPicker("Chat actions"));
    return labels();
  };
  act(() => configureQuickActions({ quickActions: ["terminal", "browser"] }));

  // No edits, no page, no Files handler (a remote chat): only New tab folds.
  render({});
  expect(await open()).toEqual(["New tab", "Rename"]);
  // Edits: Changes folds; with the side tabs shown, New tab reads Hide tabs.
  render({ hasChanges: true, sideTabs: true });
  expect(await open()).toEqual(["Changes", "Hide tabs", "Rename"]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  expect(runs).toEqual(["changes:toggle"]);
  // The diff and the preview opened since this render: the refresh as "..." opens lists the diff;
  // the preview is Browser's, lit on its button.
  render({ refresh: [HEADER_ACTIONS.changes, HEADER_ACTIONS.preview] });
  expect(await open()).toEqual(["Changes", "New tab", "Rename"]);
  // Without a Browser button, the open preview folds into "..." as before.
  act(() => configureQuickActions({ quickActions: ["terminal"] }));
  render({ refresh: [HEADER_ACTIONS.changes, HEADER_ACTIONS.preview] });
  expect(await open()).toEqual(["Changes", "Preview", "New tab", "Rename"]);
  act(() => configureQuickActions({ quickActions: ["terminal", "browser"] }));
  // Quick Chat has no tab tools: nothing folds.
  act(() => setHeaderState({ lit: [] }));
  render({ hasChanges: true, tabTools: false });
  expect(await open()).toEqual(["Rename"]);
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});
