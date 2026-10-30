// The chat menu's Edit CLAUDE.md (cx-ncc.65, Claude desktop's project instructions): a chat in a
// project folder on this Mac offers its harness's instructions file (CLAUDE.md for Claude, AGENTS.md
// for the others), and choosing it asks the app to open that file (`project.instructions`). A chat
// in its private agent-home folder, or with no folder on this Mac, has no such row.
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

afterAll(async () => {
  // Unmount and let React's scheduled work run while the window is still there: a task left for
  // after teardown reads `window.event` and fails the file (seen under CI load).
  await act(async () => root?.unmount());
  await new Promise((resolve) => setTimeout(resolve, 0));
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const labels = () =>
  [...doc.querySelectorAll(".acpmux-chat-menu-popover .acpmux-chat-menu-item")].map(
    (row) => row.querySelector(".acpmux-chat-menu-label")?.textContent,
  );

test("the chat menu edits the folder's CLAUDE.md or AGENTS.md, and only for a project on this Mac", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { instructionsRow } = await import("../src/agent-session/acpmux/header/instructionsRow");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const asked: [string, string][] = [];
  const menuFor = async (chat: { cwd: string | undefined; family: string | undefined }) => {
    const row = instructionsRow(chat, (cwd, name) => void asked.push([cwd, name]));
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => (row ? [row] : [])} />,
      ),
    );
    await act(async () => void openPicker("Chat actions"));
    return labels();
  };

  expect(await menuFor({ cwd: "/Users/me/src/app", family: "claude" })).toEqual(["Edit CLAUDE.md"]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  expect(asked).toEqual([["/Users/me/src/app", "CLAUDE.md"]]);

  expect(await menuFor({ cwd: "/Users/me/src/app", family: "codex" })).toEqual(["Edit AGENTS.md"]);
  expect(
    await menuFor({ cwd: "/Users/me/Library/Application Support/cmux/agent-home/6b16a112", family: "claude" }),
  ).toEqual([]);
  expect(await menuFor({ cwd: undefined, family: "claude" })).toEqual([]);
});

// Add Files to Project (cx-ncc.67, Claude desktop's project knowledge): the same chats offer it, and
// choosing it asks the app to add files to the folder for that harness's file (`project.addFiles`).
test("the chat menu adds files to a project on this Mac, named in its harness's file", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { projectFilesRow } = await import("../src/agent-session/acpmux/header/instructionsRow");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const asked: [string, string][] = [];
  const menuFor = async (chat: { cwd: string | undefined; family: string | undefined }) => {
    const row = projectFilesRow(chat, (cwd, name) => void asked.push([cwd, name]));
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => (row ? [row] : [])} />,
      ),
    );
    await act(async () => void openPicker("Chat actions"));
    return labels();
  };

  expect(await menuFor({ cwd: "/Users/me/src/app", family: "codex" })).toEqual(["Add Files to Project…"]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  expect(asked).toEqual([["/Users/me/src/app", "AGENTS.md"]]);
  expect(
    await menuFor({ cwd: "/Users/me/Library/Application Support/cmux/agent-home/6b16a112", family: "claude" }),
  ).toEqual([]);
  expect(await menuFor({ cwd: undefined, family: "claude" })).toEqual([]);
});
