// The chat header's right-click menu (cx-00n1, Claude Code desktop's toolbar customization): on a
// button, it moves it left or right and picks whether a click toggles its panel or opens another; it
// shows or hides every quick action and resets them. Each choice hands the App the whole new list,
// which it saves to agent-pane/layout.json.
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

test("the right-click menu moves, switches, hides and shows the quick actions", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  // Every quick action but Files shown (the list before the chat menu took the less-used ones), and
  // nothing open yet (other files in this run share the page's modules).
  configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "changes", "preview", "newTab"] });
  applyHostEvent({ kind: "headerState", value: { lit: [] } });
  const lists: string[] = [];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onSplitDown={() => {}}
        onBrowser={() => {}}
        onCustomize={(list) => {
          lists.push(list.map(({ id, mode }) => `${id}:${mode}`).join(" "));
          configureQuickActions({ quickActions: list });
        }}
        summary={null}
        menu={() => []}
      />,
    ),
  );
  const doc = host.ownerDocument;
  const rightClick = (label: string) => {
    const button = host.querySelector(`.acpmux-header-tools button[aria-label="${label}"]`)!;
    const MouseEvent = doc.defaultView!.MouseEvent;
    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
    act(() => void button.dispatchEvent(event));
  };
  const pick = (label: string) => {
    const item = doc.querySelector<HTMLButtonElement>(`.ui-context-menu [role="menuitem"][aria-label="${label}"]`);
    expect(item).not.toBeNull();
    act(() => item!.click());
  };
  rightClick("Browser");
  pick("Move Left");
  expect(lists.at(-1)).toBe(
    "terminal:toggle browser:toggle splitDown:toggle changes:toggle preview:toggle newTab:toggle",
  );
  rightClick("Browser");
  pick("Click Opens Another");
  expect(lists.at(-1)).toBe(
    "terminal:toggle browser:open splitDown:toggle changes:toggle preview:toggle newTab:toggle",
  );
  rightClick("Terminal");
  pick("Hide Terminal");
  expect(lists.at(-1)).toBe("browser:open splitDown:toggle changes:toggle preview:toggle newTab:toggle");
  expect(host.querySelector('button[aria-label="Terminal"]')).toBeNull();
  rightClick("Browser");
  pick("Show Terminal");
  // A shown button takes its default place: Terminal is first by default.
  expect(lists.at(-1)).toBe(
    "terminal:toggle browser:open splitDown:toggle changes:toggle preview:toggle newTab:toggle",
  );
  // The menu lives on the buttons: hiding the last one always shown would leave nothing to right-click.
  configureQuickActions({ quickActions: ["browser", "changes"] });
  rightClick("Browser");
  const hideBrowser = doc.querySelector<HTMLButtonElement>(
    '.ui-context-menu [role="menuitem"][aria-label="Hide Browser"]',
  );
  expect(hideBrowser?.disabled).toBe(true);
  rightClick("Browser");
  pick("Reset Buttons");
  // The default keeps the most-used four; New tab, Files and Split Down are in the chat menu.
  expect(lists.at(-1)).toBe("changes:toggle terminal:toggle browser:toggle");
  act(() => configureQuickActions({}));
});
