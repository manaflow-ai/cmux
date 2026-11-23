// l10n-allow-file: test fixture menu rows, not shipped UI.
// A "..." menu kept open runs the rows it opened with. The header's props go through stableProps.ts,
// whose callbacks used to call the newest function at the same place: after a chat switch, chat A's
// open Delete ran chat B's Delete and skipped A's guardedChatMenu (review of cmux#37907 at 7fa9cfd9,
// F1), and a row added above it moved its click to another row. Each row now runs its own action, and
// a switch hands the header new callbacks, so A's Delete goes through A's guard and never reaches B.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { guardedChatMenu, type ChatMenuItem } from "../src/agent-session/acpmux/header/chatHeaderToolsModel";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: false });
  setChatDisplay({});
  class FakeResizeObserver {
    observe() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// The chat the pane shows now, as App.tsx's `sameChat` reads it.
let selected = "";
let calls: string[] = [];

/// The menu App.tsx builds for `chat`: Delete guarded to that chat (guardedChatMenu), and `extra`
/// rows above it.
function menuOf(chat: string, extra: string[] = []): () => ChatMenuItem[] {
  return () => [
    ...extra.map((key) => ({
      key,
      label: key,
      icon: "action.edit",
      onSelect: () => void calls.push(`${chat}:${key}`),
    })),
    ...guardedChatMenu(
      [{ key: "delete", label: "Delete", icon: "action.delete", onSelect: () => void calls.push(`${chat}:delete`) }],
      () => {
        calls.push(`${chat}:guard`);
        return selected === chat;
      },
    ),
  ];
}

const header = (chat: string, menu: () => ChatMenuItem[]) => (
  <header className="acpmux-header">
    <ChatHeaderTools chat={chat} onTerminal={() => undefined} onBrowser={() => undefined} summary={null} menu={menu} />
  </header>
);

async function openMenu(container: HTMLElement) {
  const button = container.querySelector<HTMLButtonElement>('button[aria-label="Chat actions"]');
  expect(button).not.toBeNull();
  await act(async () => button!.click());
}

const row = (label: string) =>
  [...document.querySelectorAll<HTMLElement>("[role=menuitem]")].find((item) => item.textContent?.includes(label));

test("an open menu's Delete from chat A never runs chat B's handler after a switch, and A's guard runs", async () => {
  calls = [];
  selected = "a";
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(header("a", menuOf("a")));
  });
  await openMenu(container);
  const deleteA = row("Delete");
  expect(deleteA).toBeDefined();
  // The pane switches to chat B with A's menu still open.
  selected = "b";
  await act(async () => root!.render(header("b", menuOf("b"))));
  await act(async () => deleteA!.click());
  expect(calls).not.toContain("b:delete");
  expect(calls).not.toContain("b:guard");
  // A's own guard ran and refused: the chat shown is no longer A.
  expect(calls).toContain("a:guard");
  expect(calls).not.toContain("a:delete");
});

test("a row added above an open menu's Delete leaves its click on Delete", async () => {
  calls = [];
  selected = "a";
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(header("a", menuOf("a")));
  });
  await openMenu(container);
  const deleteRow = row("Delete");
  expect(deleteRow).toBeDefined();
  await act(async () => root!.render(header("a", menuOf("a", ["rename"]))));
  await act(async () => deleteRow!.click());
  expect(calls).toEqual(["a:guard", "a:delete"]);
});
