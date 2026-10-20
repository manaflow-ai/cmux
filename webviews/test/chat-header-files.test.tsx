// The chat header's Files button (cx-p4rt): off by default until the tree is styled, so the right-click
// menu lists it unchecked; checking it puts Files after Changes, a click runs the tree with its mode, and
// it lights while the App reports the tree open. A chat whose folder is not on this Mac has no Files.
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

test("Files is off until added from the right-click menu, then runs and lights like a split", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  // Every quick action but Files shown, and nothing open yet (other files in this run share the page's
  // modules).
  configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "changes", "preview", "newTab"] });
  applyHostEvent({ kind: "headerState", value: { lit: [] } });
  const runs: string[] = [];
  const lists: string[] = [];
  root = createRoot(host);
  const render = (local: boolean) =>
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={() => {}}
          onFiles={local ? (mode) => runs.push(mode) : undefined}
          onCustomize={(list) => {
            lists.push(list.map(({ id }) => id).join(" "));
            configureQuickActions({ quickActions: list });
          }}
          summary={null}
          menu={() => []}
        />,
      ),
    );
  const doc = host.ownerDocument;
  const files = () => host.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Files"]');
  render(true);
  expect(files()).toBeNull();

  const terminal = host.querySelector('.acpmux-header-tools button[aria-label="Terminal"]')!;
  const MouseEvent = doc.defaultView!.MouseEvent;
  act(
    () =>
      void terminal.dispatchEvent(
        new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
      ),
  );
  const show = doc.querySelector<HTMLButtonElement>('.ui-context-menu [role="menuitem"][aria-label="Show Files"]');
  expect(show).not.toBeNull();
  act(() => show!.click());
  expect(lists.at(-1)).toBe("terminal splitDown browser changes preview files newTab");

  expect(files()?.getAttribute("aria-pressed")).toBe("false");
  act(() => files()!.click());
  expect(runs).toEqual(["toggle"]);
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.files] } }));
  expect(files()?.getAttribute("aria-pressed")).toBe("true");

  // A remote chat's folder is not on this Mac: no Files button, even when added.
  render(false);
  expect(files()).toBeNull();
  act(() => configureQuickActions({}));
});
