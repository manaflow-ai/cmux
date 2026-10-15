// The chat header's Changes button (cx-00n1, Claude Code desktop's diff toggle): it shows when the chat
// has changes, as hidden (not disabled) as cx-qom0 asked when there are none, names itself with the diff
// viewer's keycap, runs with its mode, and lights while the App reports its diff open; an open diff keeps
// the button, so the same spot closes it.
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

test("Changes shows with the chat's changes or its open diff, and lights while the diff is open", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { ShortcutsContext } = await import("../src/agent-session/acpmux/shortcuts");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  // Changes shown as a button (it is in the chat menu by default), and nothing open yet (other files in
  // this run share the page's modules).
  configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "changes", "preview", "newTab"] });
  applyHostEvent({ kind: "headerState", value: { lit: [] } });
  const runs: string[] = [];
  root = createRoot(host);
  const render = (hasChanges: boolean) =>
    act(() =>
      root!.render(
        <ShortcutsContext.Provider value={{ [HEADER_ACTIONS.changes]: "⌃⇧⌘G" }}>
          <ChatHeaderTools
            onTerminal={() => {}}
            onBrowser={() => {}}
            hasChanges={hasChanges}
            onChanges={(mode) => runs.push(mode)}
            summary={null}
            menu={() => []}
          />
        </ShortcutsContext.Provider>,
      ),
    );
  const changes = () => host.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Changes"]');
  render(false);
  expect(changes()).toBeNull();
  render(true);
  expect(changes()?.getAttribute("title")).toBe("Changes");
  expect(changes()?.getAttribute("data-tooltip-shortcut")).toBe("⌃⇧⌘G");
  expect(changes()?.getAttribute("aria-pressed")).toBe("false");
  act(() => changes()!.click());
  expect(runs).toEqual(["toggle"]);
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.changes] } }));
  expect(changes()?.getAttribute("aria-pressed")).toBe("true");
  // The chat's edits were undone, but its diff is still open: the button stays to close it.
  render(false);
  expect(changes()?.getAttribute("aria-pressed")).toBe("true");
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [] } }));
  expect(changes()).toBeNull();
});
