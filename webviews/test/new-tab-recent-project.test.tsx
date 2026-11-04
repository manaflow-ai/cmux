// Leo 2026-10-18 (photo): a New Tab in a fresh workspace showed "Choose folder" although every chat
// he had started that day was in one project. A New Tab with no folder of its own now starts on
// the project of the most recently used chat on this Mac; a tab that has a folder keeps it, and so
// does a chat the host already named a start folder for.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, session } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { mostRecentProject } from "../src/agent-session/acpmux/sessionList";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const HOME = "/Users/you";
const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/ws-1";
const minutesAgo = (minutes: number) => Date.now() - minutes * 60_000;
const sessions = [
  session({ sessionId: "old", cwd: "/Users/you/src/older", updatedAt: minutesAgo(90) }),
  session({ sessionId: "recent", cwd: "/Users/you/src/atlas", updatedAt: minutesAgo(10) }),
  // Newer, but none is a project on this Mac: a private agent-home chat, the home folder, and
  // chats on other machines.
  session({ sessionId: "private", cwd: AGENT_HOME, updatedAt: minutesAgo(1) }),
  session({ sessionId: "home", cwd: HOME, updatedAt: minutesAgo(2) }),
  session({ sessionId: "peer", cwd: "/home/dev/api", peer: "devbox", updatedAt: minutesAgo(1) }),
  session({ sessionId: "cloud", cwd: "/workspace/app", host: "cloud-1", hostKind: "cloud", updatedAt: minutesAgo(1) }),
];

test("the most recent project is the newest local chat's folder", () => {
  expect(mostRecentProject(sessions, HOME)).toBe("/Users/you/src/atlas");
  expect(mostRecentProject([], HOME)).toBeUndefined();
  expect(mostRecentProject(sessions.slice(2), HOME)).toBeUndefined();
});

// coord-2 review: a deleted or removed folder must not become the start project. The host's
// project list (`project.list` drops a missing folder) decides which chat folders count.
test("with the host's project list, only a listed folder is the most recent project", () => {
  expect(mostRecentProject(sessions, HOME, ["/Users/you/src/older"])).toBe("/Users/you/src/older");
  expect(mostRecentProject(sessions, HOME, ["/Users/you/src/atlas/"])).toBe("/Users/you/src/atlas");
  // Not loaded yet: every local chat folder counts.
  expect(mostRecentProject(sessions, HOME, [])).toBe("/Users/you/src/atlas");
});

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
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
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
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

const noop = () => {};

/// Types `text` into the New Tab prompt (the composer's Markdown field) once its editor is made.
async function typePrompt(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await act(async () => {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.type(text);
  });
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

/// Return in the prompt: the page asks.
async function pressReturn(editor: HTMLElement) {
  await act(async () =>
    editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
}

async function askFrom(fields: { cwd?: string; startCwd?: string; knownProjects?: string[] }) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  const calls: unknown[][] = [];
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat(sessions)}
        omnibar={EMPTY_OMNIBAR}
        lastAgent="claude"
        home={HOME}
        {...fields}
        onAsk={(...args) => calls.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const editor = await typePrompt("fix the flaky upload test");
  const location = host.querySelector(".nt-location")?.textContent ?? "";
  await pressReturn(editor);
  return { location, folder: calls[0]?.[2] };
}

test("a New Tab with no folder starts on the most recent project", async () => {
  const { location, folder } = await askFrom({});
  expect(location).toContain("atlas");
  expect(location).not.toContain("Choose folder");
  expect(folder).toBe("/Users/you/src/atlas");
});

test("a New Tab in the home folder or a private folder starts on the most recent project too", async () => {
  expect((await askFrom({ cwd: HOME })).folder).toBe("/Users/you/src/atlas");
  expect((await askFrom({ cwd: AGENT_HOME })).folder).toBe("/Users/you/src/atlas");
});

test("a New Tab skips a recent chat folder the host does not list", async () => {
  expect((await askFrom({ knownProjects: ["/Users/you/src/older"] })).folder).toBe("/Users/you/src/older");
});

// coord-2 review: the chip must not change under the user while a chat elsewhere updates.
test("the start project stays put when a newer chat lands", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  const calls: unknown[][] = [];
  const page = (list: typeof sessions) => (
    <NewTabScreen
      snapshot={noChat(list)}
      omnibar={EMPTY_OMNIBAR}
      lastAgent="claude"
      home={HOME}
      onAsk={(...args) => calls.push(args)}
      onOpen={noop}
      onSearch={noop}
      onShell={noop}
      onJump={noop}
      onOpenSession={noop}
      onShowAll={noop}
    />
  );
  await act(async () => root!.render(page(sessions)));
  const newer = session({ sessionId: "newer", cwd: "/Users/you/src/billing", updatedAt: Date.now() });
  await act(async () => root!.render(page([...sessions, newer])));
  expect(host.querySelector(".nt-location")?.textContent).toContain("atlas");
  const editor = await typePrompt("fix the flaky upload test");
  await pressReturn(editor);
  expect(calls[0]?.[2]).toBe("/Users/you/src/atlas");
});

test("a tab with a project folder, or a start folder from the host, keeps it", async () => {
  expect((await askFrom({ cwd: "/Users/you/src/billing" })).folder).toBe("/Users/you/src/billing");
  const named = await askFrom({ startCwd: "/Users/you/src/billing" });
  expect(named.location).toContain("billing");
  expect(named.folder).toBeUndefined();
});

// Leo 2026-10-18 (ChatGPT and Claude Code screenshots): the project menu offers "Do not work in a
// project". Picking it stops the most-recent-project start, and the chat starts in no project
// (`chat.new` with `noProject`): the host's private folder, never the tab's or the start folder.
test("Do not work in a project starts the chat in no project", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  const calls: unknown[][] = [];
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat(sessions)}
        omnibar={EMPTY_OMNIBAR}
        lastAgent="claude"
        home={HOME}
        startCwd="/Users/you/src/billing"
        projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        onAsk={(...args) => calls.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>(".nt-location .acpmux-location-button")!.click());
  const option = [...window.document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (row) => row.textContent === "Do not work in a project",
  );
  expect(option).toBeDefined();
  await act(async () => option!.click());
  expect(host.querySelector(".nt-location")?.textContent).toContain("No project");
  const editor = await typePrompt("sketch a name for the app");
  await pressReturn(editor);
  expect(calls[0]?.[2]).toBeUndefined();
  expect(calls[0]?.[4]).toBe(true);
});

test("a no-project ask sends chat.new with noProject and no folder", async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const sent: [string, unknown][] = [];
  const actions = newTabScreenActions({
    // chat.new answers with the started session, as the host does: an empty answer is a failed
    // start, whose rejection would land in the next test (#28543).
    callNative: async (method, params) => (sent.push([method, params]), method === "chat.new" ? "started" : undefined),
    cwd: HOME,
    chatCwd: "/Users/you/src/billing",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  await actions.onAsk("claude", "hi", undefined, undefined, true);
  expect(sent.find(([method]) => method === "chat.new")?.[1]).toEqual({ harness: "claude", noProject: true });
});

// Leo 2026-10-19: a New Tab painted "Choose folder" on its first frame, then the recent project once
// its own daemon connection listed the chats. A page that hears this Mac's list keeps its newest
// folders for the run (every agent page shares one localStorage); the next page decides from them
// as it mounts, and a page with nothing to go on holds the chip's place instead of a wrong label.
test("a page's heard chats name the next page's recent project before its own list", async () => {
  const stored = new Map<string, string>();
  const store = {
    getItem: (key: string) => stored.get(key) ?? null,
    setItem: (key: string, value: string) => void stored.set(key, value),
  };
  const had = "localStorage" in scope;
  const before = scope.localStorage;
  scope.localStorage = store;
  try {
    const recent = await import("../src/agent-session/acpmux/newtab/recentProject");
    recent.resetRecentProjectForTests();
    expect(recent.initialRecentProject([], HOME, [])).toBeUndefined();
    // Another machine's list (a chat opened on a peer) is not this Mac's.
    recent.rememberRecentFolders({ origin: "remote", sessions: noChat(sessions).sessions });
    expect(recent.initialRecentProject([], HOME, [])).toBeUndefined();
    recent.rememberRecentFolders({ origin: "local", sessions: noChat(sessions).sessions });
    // The home folder and agent-home are no project; the newest local folder is.
    expect(recent.initialRecentProject([], HOME, [])).toBe("/Users/you/src/atlas");
    // A page on another machine (the host gives it no home) never starts in this Mac's folder.
    expect(recent.initialRecentProject([], undefined, [])).toBeUndefined();
    // The host's project list still decides, and the page's own chats come first.
    expect(recent.initialRecentProject([], HOME, ["/Users/you/src/older"])).toBe("/Users/you/src/older");
    const own = [session({ sessionId: "own", cwd: "/Users/you/src/billing", updatedAt: minutesAgo(0) })];
    expect(recent.initialRecentProject(noChat(own).sessions, HOME, [])).toBe("/Users/you/src/billing");
    // An empty list (a connection before its first answer) keeps what was heard.
    recent.rememberRecentFolders({ origin: "local", sessions: [] });
    expect(recent.initialRecentProject([], HOME, [])).toBe("/Users/you/src/atlas");

    // The New Tab's chip names it on its first render, before any chat reaches the page.
    const { createRoot } = await import("react-dom/client");
    const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
    act(() => root?.unmount());
    root = createRoot(host);
    act(() =>
      root!.render(
        <NewTabScreen
          snapshot={noChat([])}
          omnibar={EMPTY_OMNIBAR}
          lastAgent="claude"
          home={HOME}
          chatsPending
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />,
      ),
    );
    expect(host.querySelector(".nt-location")?.textContent).toContain("atlas");
    expect(host.querySelector(".nt-location")?.hasAttribute("data-project-pending")).toBe(false);
  } finally {
    if (had) scope.localStorage = before;
    else delete scope.localStorage;
  }
});

test("with no recent project known yet, the folder chip holds its place until the chats are listed", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  const page = (list: typeof sessions, pending: boolean) => (
    <NewTabScreen
      snapshot={noChat(list)}
      omnibar={EMPTY_OMNIBAR}
      lastAgent="claude"
      home={HOME}
      {...(pending ? { chatsPending: true } : {})}
      onAsk={noop}
      onOpen={noop}
      onSearch={noop}
      onShell={noop}
      onJump={noop}
      onOpenSession={noop}
      onShowAll={noop}
    />
  );
  await act(async () => root!.render(page([], true)));
  expect(host.querySelector(".nt-location")?.hasAttribute("data-project-pending")).toBe(true);
  await act(async () => root!.render(page(sessions, false)));
  expect(host.querySelector(".nt-location")?.hasAttribute("data-project-pending")).toBe(false);
  expect(host.querySelector(".nt-location")?.textContent).toContain("atlas");
  // A daemon with no chats at all: the chip shows as it is.
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(page([], false)));
  expect(host.querySelector(".nt-location")?.hasAttribute("data-project-pending")).toBe(false);
});

test("enabled recent chats show placeholders until the first session list settles", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([]);
  act(() => root?.unmount());
  root = createRoot(host);
  const page = (list: typeof sessions, pending: boolean) => (
    <NewTabScreen
      snapshot={noChat(list)}
      omnibar={EMPTY_OMNIBAR}
      template="threads"
      pageWidgets={new Set(["chats"])}
      chatsPending={pending}
      lastAgent="claude"
      onAsk={noop}
      onOpen={noop}
      onSearch={noop}
      onShell={noop}
      onJump={noop}
      onOpenSession={noop}
      onShowAll={noop}
    />
  );
  await act(async () => root!.render(page([], true)));
  expect(host.querySelector(".nt-cards[aria-busy=true]")).not.toBeNull();
  expect(host.querySelector(".nt-chats-empty")).toBeNull();
  await act(async () => root!.render(page(sessions, false)));
  expect(host.querySelector(".nt-cards[aria-busy=true]")).toBeNull();
  expect(host.querySelector(".nt-card-title")?.textContent).toBeTruthy();
  await act(async () => root!.render(page(sessions, true)));
  expect(host.querySelector(".nt-cards[aria-busy=true]")).toBeNull();
  expect(host.querySelector(".nt-card-title")?.textContent).toBeTruthy();
  await act(async () => root!.render(page([], false)));
  expect(host.querySelector(".nt-cards[aria-busy=true]")).toBeNull();
  expect(host.querySelector(".nt-chats-empty")).not.toBeNull();
});
