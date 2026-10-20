// All chats on the New Tab page (cx-heu): the chat index pushes every change (FSEvents, `deviceChats`).
// A loaded list reads its first page again on each push and keeps the pages below it, so a chat that
// changed while the page is open moves to the top without a reload; a search is left alone.
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
  // TanStack Virtual observes the list's size; JSDOM has no ResizeObserver.
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
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

const row = (key: string, updatedAt: number) => ({ key, harness: "claude", title: key, cwd: "/tmp/cmux", updatedAt });

test("a loaded All chats list reads its first page again when the chat index pushes a change", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  const firstPages: number[] = [];
  let pushed = false;
  const load = async (params: { query?: string; cursor?: string; limit: number }) => {
    if (params.cursor) return { chats: [row("older", 1)], ready: true };
    firstPages.push(firstPages.length);
    return pushed
      ? { chats: [row("changed", 5), row("a", 3)], nextCursor: "page-2", ready: true }
      : { chats: [row("a", 3), row("changed", 2)], nextCursor: "page-2", ready: true };
  };

  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  // The first page's reply settles: the list is loaded and ready before the push.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(firstPages.length).toBe(1);

  // A chat changed on disk: the index pushes its newest chats.
  pushed = true;
  await act(async () => setDeviceChats([{ key: "changed", harness: "claude", updatedAt: 5 }]));
  expect(firstPages.length).toBe(2);
});

test("the first page read again goes on top of the loaded rows, which keep the later pages", async () => {
  const { mergeFirstPage } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const loaded = [row("a", 3), row("changed", 2), row("b", 1), row("older", 0)];
  expect(mergeFirstPage([row("changed", 5), row("a", 3)], loaded).map((chat) => chat.key)).toEqual([
    "changed",
    "a",
    "b",
    "older",
  ]);
});

test("the list shown again draws its last first page while it reads the first page again", async () => {
  // Leo, 2026-10-19: the New Tab page shows a fresh All chats list each time, and it drew empty
  // until its first page came back, then filled (and could change its layout).
  const React = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { useChatPages } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  act(() => root?.unmount());
  const seen: string[][] = [];
  function Probe(props: { load: Parameters<typeof useChatPages>[0] }) {
    const pages = useChatPages(props.load);
    React.useLayoutEffect(() => {
      seen.push(pages.state.rows.map((chat) => chat.key));
    });
    return null;
  }
  root = createRoot(host);
  await act(async () => root!.render(<Probe load={async () => ({ chats: [row("kept-chat", 9)], ready: true })} />));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(seen.at(-1)).toEqual(["kept-chat"]);
  act(() => root!.unmount());
  seen.length = 0;
  // Shown again: its first page has not answered yet.
  root = createRoot(host);
  await act(async () => root!.render(<Probe load={() => new Promise(() => {})} />));
  expect(seen.filter((rows) => rows.join() !== "kept-chat")).toHaveLength(0);
});
