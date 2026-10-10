// The chat menu's Copy submenu (cx-qom0), as in ChatGPT: Copy link with its keycap, the last
// response, and the whole chat as Markdown (prompts quoted, turns split by a rule). The header renders in jsdom; the menu opens the way
// automation opens it (pickerOpeners), and a row's selection reaches the clipboard.
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
const copied: string[] = [];

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.defineProperty(window.navigator, "clipboard", {
    value: { writeText: async (text: string) => void copied.push(text) },
  });
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

const rows = (popup: Element) =>
  [...popup.querySelectorAll(".acpmux-chat-menu-item")].map((row) =>
    [row.querySelector(".acpmux-chat-menu-label")?.textContent, row.querySelector("kbd")?.textContent].filter(Boolean),
  );

test("Copy offers the link with its keycap, the last response and the chat as Markdown", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { copyRow } = await import("../src/agent-session/acpmux/header/copyRow");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const { copyText } = await import("../src/agent-session/acpmux/conversation/clipboard");
  const { ShortcutsContext, SHORTCUT_ACTIONS } = await import("../src/agent-session/acpmux/shortcuts");
  const transcript = [
    { id: "1", version: 1, at: 1, kind: "user", text: "List the files" },
    { id: "2", version: 1, at: 2, kind: "assistant", text: "Two files." },
    { id: "3", version: 1, at: 3, kind: "user", text: "Which is larger?\nBy bytes" },
    { id: "4", version: 1, at: 4, kind: "activity", text: "ls -l" },
    { id: "5", version: 1, at: 5, kind: "assistant", text: "a.txt" },
    { id: "6", version: 1, at: 6, kind: "assistant", text: "by 2 KB." },
  ];
  const copy = copyRow({ link: "cmux://chat/s1", rows: transcript }, (text) => void copyText(text));
  root = createRoot(doc.getElementById("root")!);
  act(() =>
    root!.render(
      <ShortcutsContext.Provider value={{ [SHORTCUT_ACTIONS.copyTabLink]: "⇧⌘C" }}>
        <ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => (copy ? [copy] : [])} />
      </ShortcutsContext.Provider>,
    ),
  );
  await act(async () => void openPicker("Chat actions"));
  expect(rows(doc.querySelector(".acpmux-chat-menu-popover")!)).toEqual([["Copy"]]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  const popups = doc.querySelectorAll(".acpmux-chat-menu-popover");
  expect(popups.length).toBe(2);
  expect(rows(popups[1])).toEqual([["Copy link", "⇧⌘C"], ["Copy last response"], ["Copy as Markdown"]]);
  const items = [...popups[1].querySelectorAll<HTMLElement>(".acpmux-chat-menu-item")];
  await act(async () => items[2].click());
  expect(copied).toEqual([
    "> List the files\n\nTwo files.\n\n---\n\n> Which is larger?\n> By bytes\n\na.txt\n\nby 2 KB.",
  ]);
});
