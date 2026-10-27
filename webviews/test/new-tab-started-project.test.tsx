// Leo 2026-10-21 (screenshot: the New Tab project chip read "leo-workspace · briefs/2026-10-20-gui-push",
// a folder only agents worked in): "we dont wanna have stuff constantly get clobbered by agents making
// projects and then the new workspace has to keep redoing the default... your recently PICKED AND
// STARTED CHAT... makes more sense". A New Tab with no folder of its own starts in the project of the
// chat the person last picked and started from a composer; chats agents, the CLI or the socket start
// (lanes, worktrees, briefs folders) never move it. The newest chat's folder is only the fallback.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, session } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";

const HOME = "/Users/you";
const PICKED = "/Users/you/src/atlas";
const AGENT_FOLDER = "/Users/you/Projects/leo-workspace/briefs/2026-10-20-gui-push";
const minutesAgo = (minutes: number) => Date.now() - minutes * 60_000;
const theirs = session({ sessionId: "person", cwd: PICKED, updatedAt: minutesAgo(60) });
// Chats agents started since (a coordinator and its lanes), newer than the person's.
const agents = [
  session({ sessionId: "lane-1", cwd: AGENT_FOLDER, updatedAt: minutesAgo(2) }),
  session({ sessionId: "lane-2", cwd: "/Users/you/Projects/checkouts/cmux/lane-2", updatedAt: minutesAgo(1) }),
];

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const stored = new Map<string, string>();
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
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // Every agent page shares one store for the run (AgentPaneView.sharedDataStore).
    localStorage: {
      getItem: (key: string) => stored.get(key) ?? null,
      setItem: (key: string, value: string) => void stored.set(key, value),
      removeItem: (key: string) => void stored.delete(key),
    },
  });
  host = window.document.getElementById("root")!;
});

beforeEach(() => stored.clear());

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

/// The person's send on a New Tab page: Enter with `picked` as the page's project pick, through the
/// page's real actions (screenActions). Returns what the app was told.
async function startChat(
  picked: string | undefined,
  options: { noProject?: boolean; startsHere?: boolean; start?: "started" | "refused" | "failed" } = {},
) {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const sent: [string, unknown][] = [];
  let starting: Promise<unknown> = Promise.resolve();
  const actions = newTabScreenActions({
    callNative: (method, params) => {
      sent.push([method, params]);
      if (method !== "chat.new") return Promise.resolve();
      // `chat.new` resolves to the chat it started; none when the host refused it; a rejection when
      // the daemon went away.
      const start = options.start ?? "started";
      starting =
        start === "failed"
          ? Promise.reject(new Error("daemon stopped"))
          : Promise.resolve(start === "started" ? "session-1" : undefined);
      return starting;
    },
    cwd: HOME,
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
    ...(options.startsHere === false ? { startsHere: () => false } : {}),
  });
  await Promise.resolve(
    actions.onAsk("claude", "fix the flaky upload test", picked, undefined, options.noProject),
  ).catch(() => undefined);
  // The start settles, and what follows it runs.
  await starting.catch(() => undefined);
  await Promise.resolve();
  return sent;
}

/// A fresh New Tab page (no folder of its own) over `sessions`: its chip and the folder Enter asks in.
async function newTab(
  sessions: ReturnType<typeof session>[],
  fields: { knownProjects?: string[] | null; startedProject?: string; home?: string | undefined } = {},
) {
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
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "fix the flaky upload test");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const chip = host.querySelector(".nt-location")?.textContent ?? "";
  await act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  return { chip, folder: calls[0]?.[2] };
}

test("a project the person picks and starts a chat in is the next New Tab's default", async () => {
  await startChat(PICKED);
  // A newer chat in another folder, which no composer send named, does not take it.
  const page = await newTab([
    theirs,
    session({ sessionId: "other", cwd: "/Users/you/src/billing", updatedAt: minutesAgo(5) }),
  ]);
  expect(page.chip).toContain("atlas");
  expect(page.folder).toBe(PICKED);
});

test("chats agents, the CLI or the socket start in another folder never change the default", async () => {
  await startChat(PICKED);
  // Agents' chats reach the page only as newer rows of the chat list: no composer send names them.
  const page = await newTab([theirs, ...agents]);
  expect(page.chip).not.toContain("gui-push");
  expect(page.chip).toContain("atlas");
  expect(page.folder).toBe(PICKED);
});

test("the app's copy names it after a relaunch, and this run's latest start wins over it", async () => {
  expect((await newTab([theirs, ...agents], { startedProject: PICKED })).folder).toBe(PICKED);
  await startChat("/Users/you/src/billing");
  expect((await newTab([theirs, ...agents], { startedProject: PICKED })).folder).toBe("/Users/you/src/billing");
});

test("the app is told the started project, and only for a chat started in a project on this Mac", async () => {
  const sent = await startChat(PICKED);
  expect(sent).toContainEqual(["newTab.remember", { started: PICKED }]);
  // Do not work in a project, or a page on another machine: the default stays as it was.
  stored.clear();
  const none = await startChat(undefined, { noProject: true });
  const remote = await startChat("/home/dev/api", { startsHere: false });
  expect(
    [...none, ...remote].some(([method, params]) => method === "newTab.remember" && "started" in (params as object)),
  ).toBe(false);
  // Nothing was started in a project here, so the page falls back to the newest chat's folder.
  expect((await newTab([theirs, ...agents])).folder).toBe("/Users/you/Projects/checkouts/cmux/lane-2");
});

test("with no started chat, or one whose folder the host no longer lists, the newest chat's folder is the default", async () => {
  expect((await newTab([theirs, ...agents])).folder).toBe("/Users/you/Projects/checkouts/cmux/lane-2");
  await startChat(PICKED);
  expect((await newTab([theirs, ...agents], { knownProjects: [AGENT_FOLDER] })).folder).toBe(AGENT_FOLDER);
});

test("the New Tab context's started project reaches the page, a relative or home folder never", async () => {
  const { newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  expect(newTabHost({ newTab: { startedProject: PICKED } })?.startedProject).toBe(PICKED);
  expect(newTabHost({ newTab: { startedProject: "briefs/2026-10-20-gui-push" } })?.startedProject).toBeUndefined();
  expect(newTabHost({ newTab: { startedProject: HOME } })?.startedProject).toBeUndefined();
});

// Codex review of #24274: a start the host refuses, or one that fails because the daemon went away,
// creates no chat, so its folder never becomes the default.
test("a refused or failed chat start leaves the remembered project unchanged", async () => {
  await startChat(PICKED);
  for (const start of ["refused", "failed"] as const) {
    const sent = await startChat("/Users/you/src/billing", { start });
    expect(sent.some(([method, params]) => method === "newTab.remember" && "started" in (params as object))).toBe(
      false,
    );
    expect((await newTab([theirs, ...agents])).folder).toBe(PICKED);
  }
});

/// The classic New Tab page (Debug Settings `newTab.layout` "a") with no folder of its own: the
/// project its chip names and the folder Enter asks in.
async function classicTab(fields: {
  home?: string;
  knownProjects?: string[] | null;
  startedProject?: string;
  cwd?: string;
}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  act(() => root?.unmount());
  root = createRoot(host);
  const asked: unknown[][] = [];
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat([theirs, ...agents])}
        initialKind="agent"
        {...fields}
        onSubmit={(...args) => void asked.push(args)}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const chip = host.querySelector(".acpmux-newtab-context .acpmux-project-button")?.textContent ?? "";
  const form = host.querySelector("form")!;
  await act(async () => form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })));
  return { chip, folder: asked[0]?.[2] };
}

// Codex review of #24274: the classic page reads the same default, on this Mac only, and only while
// the host still lists it.
test("the classic New Tab page starts on the started project, else the newest listed chat folder", async () => {
  await startChat(PICKED);
  const page = await classicTab({ home: HOME, cwd: HOME });
  expect(page.chip).toContain("atlas");
  expect(page.folder).toBe(PICKED);
  // A started project the host no longer lists gives way to the newest chat folder it lists.
  expect((await classicTab({ home: HOME, cwd: HOME, knownProjects: [AGENT_FOLDER] })).folder).toBe(AGENT_FOLDER);
  // The app's copy after a relaunch, when this run started nothing.
  stored.clear();
  expect((await classicTab({ home: HOME, startedProject: PICKED })).folder).toBe(PICKED);
});

test("a New Tab on another machine never starts in this Mac's started project", async () => {
  await startChat(PICKED);
  // Another machine's page has no `home` (NewTabPageMachine) and no `startedProject` in its context.
  const classic = await classicTab({ cwd: "/home/dev" });
  expect(classic.chip).not.toContain("atlas");
  expect(classic.folder).toBe("/home/dev");
  const screen = await newTab([], { home: undefined });
  expect(screen.chip).not.toContain("atlas");
  expect(screen.folder).toBeUndefined();
});

// Codex review of #24274: the host's project store answered and lists no project (every entry
// removed or missing). That is not "not loaded yet": no chat folder and no stored started project
// counts, on either New Tab page.
test("a project list that answered empty accepts no chat or started folder", async () => {
  const { firstProject, mostRecentProject } = await import("../src/agent-session/acpmux/sessionList");
  expect(firstProject([PICKED], HOME, null)).toBeUndefined();
  expect(mostRecentProject([theirs, ...agents], HOME, null)).toBeUndefined();
  // Not loaded yet (absent or empty): every folder still counts.
  expect(firstProject([PICKED], HOME, [])).toBe(PICKED);
  expect(firstProject([PICKED], HOME)).toBe(PICKED);

  await startChat(PICKED);
  const screen = await newTab([theirs, ...agents], { knownProjects: null, startedProject: PICKED });
  expect(screen.chip).not.toContain("atlas");
  expect(screen.chip).not.toContain("lane-2");
  expect(screen.folder).toBeUndefined();
  const classic = await classicTab({ home: HOME, cwd: HOME, knownProjects: null, startedProject: PICKED });
  expect(classic.chip).not.toContain("atlas");
  expect(classic.folder).toBe(HOME);
});
