// The chat header's top right (cx-qom0): every button names itself in a tooltip, with its keycap
// when the action has one, as in ChatGPT. The header renders in jsdom with the host's keycaps; the
// pane's tooltip layer (ui/titleTooltips.ts) shows each `title`.
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

test("every header button has a tooltip, with its shortcut when it has one", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { ShortcutsContext } = await import("../src/agent-session/acpmux/shortcuts");
  const keycaps = { [HEADER_ACTIONS.terminal]: "⌘D", [HEADER_ACTIONS.browser]: "⇧⌘L" };
  root = createRoot(host);
  act(() =>
    root!.render(
      <ShortcutsContext.Provider value={keycaps}>
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={() => {}}
          summary={null}
          menu={() => [{ key: "rename", label: "Rename", icon: "action.edit" }]}
        />
      </ShortcutsContext.Provider>,
    ),
  );
  const buttons = [...host.querySelectorAll(".acpmux-header-tools button")];
  expect(buttons.length).toBe(3);
  expect(buttons.map((button) => [button.getAttribute("aria-label"), button.getAttribute("title")])).toEqual([
    ["Terminal", "Terminal (⌘D)"],
    ["Browser", "Browser (⇧⌘L)"],
    ["Chat actions", "Chat actions"],
  ]);
});
