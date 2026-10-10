// The chat header's top right (cx-qom0): every button names itself in a tooltip, with its keycap
// when the action has one, as in ChatGPT; [+] New tab reads Hide tabs in the same spot once the
// tabs beside the chat show. The header renders in jsdom with the host's keycaps; the
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

test("every header button has a tooltip, with its shortcut when it has one; New tab turns into Hide tabs in place", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { ShortcutsContext } = await import("../src/agent-session/acpmux/shortcuts");
  const keycaps = { [HEADER_ACTIONS.terminal]: "⌘D", [HEADER_ACTIONS.browser]: "⇧⌘L" };
  root = createRoot(host);
  const render = (sideTabs: boolean) =>
    act(() =>
      root!.render(
        <ShortcutsContext.Provider value={keycaps}>
          <ChatHeaderTools
            onTerminal={() => {}}
            onBrowser={() => {}}
            sideTabs={sideTabs}
            onSideTabs={() => {}}
            summary={null}
            menu={() => [{ key: "rename", label: "Rename", icon: "action.edit" }]}
          />
        </ShortcutsContext.Provider>,
      ),
    );
  const named = () =>
    [...host.querySelectorAll(".acpmux-header-tools button")].map((button) => [
      button.getAttribute("aria-label"),
      button.getAttribute("title"),
    ]);
  render(false);
  expect(named()).toEqual([
    ["Terminal", "Terminal (⌘D)"],
    ["Browser", "Browser (⇧⌘L)"],
    ["New tab", "New tab"],
    ["Chat actions", "Chat actions"],
  ]);
  // [+] New tab becomes Hide tabs on the same button, so the next click lands on it again.
  const newTab = host.querySelectorAll(".acpmux-header-tools button")[2];
  render(true);
  expect(host.querySelectorAll(".acpmux-header-tools button")[2]).toBe(newTab);
  expect(named()[2]).toEqual(["Hide tabs", "Hide tabs"]);
  expect(newTab.getAttribute("aria-pressed")).toBe("true");
});
