// l10n-allow-file: test fixtures.
// The New Tab's Chats list holds still (Leo 2026-10-13, cosmic-gray): two New Tabs showed the same
// chat as "1m" and "now", each lane showed twice (by its name and again by its Claude Code
// transcript's first prompt), a chat whose last turn failed read "Disconnected" while acpmux said
// ready, and the variable-width time pushed the harness icon about as it changed.
import { afterAll, afterEach, beforeAll, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { recentSessions } from "../src/agent-session/acpmux/NewTabPage";
import { recentChatCards } from "../src/agent-session/acpmux/newtab/screenModel";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
const roots: Root[] = [];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=a></div><div id=b></div>", { pretendToBeVisual: true }).window;
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
  });
});

afterEach(async () => {
  for (const root of roots.splice(0)) await act(async () => root.unmount());
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([]);
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const MINUTE = 60_000;
// A minute boundary on the wall clock.
const T0 = Math.floor(Date.UTC(2026, 9, 13, 15, 0) / MINUTE) * MINUTE;

function lane(fields: Partial<AcpmuxSessionEntry> & Record<string, unknown>): AcpmuxSessionEntry {
  return {
    sessionId: "lane-1",
    name: "cg-next-reds",
    harness: "claude",
    status: "ready",
    cwd: "/Users/you/src/cmux",
    updatedAt: T0 + 5_000,
    ...fields,
  } as AcpmuxSessionEntry;
}

async function mount(id: "a" | "b", sessions: AcpmuxSessionEntry[]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root = createRoot(window.document.getElementById(id)!);
  roots.push(root);
  await act(async () =>
    root.render(
      <NewTabScreen
        template="default"
        snapshot={noChat(sessions)}
        lastAgent="claude"
        loadChatsPage={async () => ({ ready: true, chats: [] })}
        onOpenChat={noop}
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
  return window.document.getElementById(id)!;
}

const rows = (page: HTMLElement) =>
  [...page.querySelectorAll<HTMLElement>(".nt-cards[data-variant=list] .nt-card")].map((row) => ({
    title: row.querySelector(".nt-card-title")?.textContent,
    state: row.querySelector(".nt-card-message")?.textContent,
    age: row.querySelector(".nt-card-age")?.textContent,
  }));

test("two New Tabs drawn at different moments of one minute show the same age", async () => {
  const now = spyOn(Date, "now");
  try {
    now.mockReturnValue(T0 + 20_000);
    const first = await mount("a", [lane({})]);
    now.mockReturnValue(T0 + 55_000);
    const second = await mount("b", [lane({})]);
    expect(rows(second).map((row) => row.age)).toEqual(rows(first).map((row) => row.age));
  } finally {
    now.mockRestore();
  }
});

test("same-time chats keep a deterministic order when the snapshot order changes", () => {
  const sessions = [
    lane({ sessionId: "chat-b", updatedAt: T0, name: "Second chat" }),
    lane({ sessionId: "chat-a", updatedAt: T0, name: "First chat" }),
  ];
  expect(recentSessions(sessions, 2, false).map((session) => session.sessionId)).toEqual(["chat-a", "chat-b"]);
  expect(recentSessions([...sessions].reverse(), 2, false).map((session) => session.sessionId)).toEqual([
    "chat-a",
    "chat-b",
  ]);
});

test("a lane shows once, by its name, not again by its transcript's first prompt", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  const agent = "01a13744-474a-4b2e-9f0e-7c1d2e3f4a5b";
  setDeviceChats([
    {
      key: `claude-code:${agent}`,
      harness: "claude-code",
      title: "You are a lane in Leo's agent lanes",
      updatedAt: T0,
    },
    { key: "claude-code:another", harness: "claude-code", title: "Fix the flaky upload test", updatedAt: T0 - MINUTE },
  ]);
  const page = await mount("a", [lane({ agentSessionId: agent })]);
  expect(rows(page).map((row) => row.title)).toEqual(["cg-next-reds", "Fix the flaky upload test"]);
});

// A lane's child sessions, started from coordinator messages (Leo 2026-10-13: "Coordinator: ..."
// rows at the top of Chats), fold under their parent: neither the child's acpmux session
// (`spawnedBy`) nor its transcript in the device index (`parent`) is listed on its own.
test("a chat another chat's agent started is not listed on its own", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([
    {
      key: "claude-code:child-transcript",
      harness: "claude-code",
      title: "Coordinator: fix the reds",
      updatedAt: T0,
      parent: "claude-code:lane",
    },
    { key: "claude-code:another", harness: "claude-code", title: "Fix the flaky upload test", updatedAt: T0 - MINUTE },
  ]);
  const page = await mount("a", [
    lane({}),
    lane({ sessionId: "child", name: "Coordinator: land the PR", spawnedBy: "lane-1", updatedAt: T0 + 1 }),
  ]);
  expect(rows(page).map((row) => row.title)).toEqual(["cg-next-reds", "Fix the flaky upload test"]);
});

// The parent's row keeps its children in a collapsed list with a count; opened, it lists them under
// it (Leo 2026-10-14).
test("a chat's children fold into a list under its row", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([]);
  const page = await mount("a", [
    lane({}),
    lane({ sessionId: "child", name: "Coordinator: land the PR", spawnedBy: "lane-1", updatedAt: T0 + 1 }),
    lane({ sessionId: "child-2", name: "Coordinator: fix the reds", spawnedBy: "lane-1", updatedAt: T0 + 2 }),
  ]);
  expect(rows(page).map((row) => row.title)).toEqual(["cg-next-reds"]);
  const toggle = page.querySelector<HTMLButtonElement>(".nt-card-children-toggle")!;
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  expect(toggle.textContent).toBe("2");
  await act(async () => toggle.click());
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  expect(rows(page).map((row) => row.title)).toEqual([
    "cg-next-reds",
    "Coordinator: fix the reds",
    "Coordinator: land the PR",
  ]);
});

// A child lists on its own when its parent is not in the list (deleted, or a summary from before
// the daemon dropped the tag) or when it waits on the user, so no chat is hidden everywhere.
test("a child whose parent is gone, or that waits on the user, lists on its own", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([]);
  const page = await mount("a", [
    lane({}),
    lane({ sessionId: "orphan", name: "Coordinator: orphan", spawnedBy: "deleted-lane", updatedAt: T0 + 1 }),
    lane({ sessionId: "asks", name: "Coordinator: asks", spawnedBy: "lane-1", indicator: "input", updatedAt: T0 + 2 }),
  ]);
  expect(rows(page).map((row) => row.title)).toEqual(["Coordinator: asks", "cg-next-reds", "Coordinator: orphan"]);
  expect(page.querySelector(".nt-card-children-toggle")).toBeNull();
});

test("a chat whose last turn failed reads Failed; one that lost its agent reads Disconnected", async () => {
  const page = await mount("a", [
    lane({ sessionId: "failed", name: "continue", lastTurn: { status: "failed" }, indicator: "failed" }),
    lane({ sessionId: "lost", name: "cg-lane-adopt", status: "disconnected", indicator: "lost", updatedAt: T0 }),
  ]);
  expect(Object.fromEntries(rows(page).map((row) => [row.title, row.state]))).toEqual({
    continue: "Failed",
    "cg-lane-adopt": "Disconnected",
  });
});

// The list's geometry, as its stylesheet sets it (the test DOM lays nothing out): the age is the
// row's last box, in a fixed-width right-aligned column of tabular figures, so "now", "9m" and
// "10m" leave the harness icon where it is; and the rows' text sits on the title's edges.
test("the age is a fixed, right-aligned column after the harness icon, and rows share the title's edges", async () => {
  const page = await mount("a", [lane({})]);
  const meta = page.querySelector<HTMLElement>(".nt-cards[data-variant=list] .nt-card-meta")!;
  expect([...meta.children].map((child) => child.getAttribute("class")?.split(" ")[0]).at(-1)).toBe("nt-card-age");

  const css = readFileSync(new URL("../src/agent-session/acpmux/newtab/screen.css", import.meta.url), "utf8");
  const element = window.document.createElement("style");
  element.textContent = css;
  window.document.head.append(element);
  const sheet = element.sheet!;
  const rule = (selector: string) =>
    [...sheet.cssRules]
      .filter((candidate): candidate is CSSStyleRule => (candidate as CSSStyleRule).selectorText === selector)
      .map((candidate) => candidate.style);
  const style = (selector: string, property: string) =>
    rule(selector)
      .map((declaration) => declaration.getPropertyValue(property))
      .filter(Boolean)
      .at(-1);
  const age = '.nt-cards[data-variant="list"] .nt-card-age';
  expect({
    width: style(age, "width"),
    align: style(age, "text-align"),
    grow: style(age, "flex"),
    figures: style(".nt-card-age", "font-variant-numeric"),
    edge: style('.nt-cards[data-variant="list"]', "margin-inline"),
    rowPadding: style('.nt-cards[data-variant="list"] .nt-card', "padding"),
  }).toEqual({
    width: "3.2em",
    align: "right",
    grow: "0 0 auto",
    figures: "tabular-nums",
    edge: "-10px",
    rowPadding: "0px 10px",
  });
});

test("same-time device chats keep a deterministic order when the host's push order changes", () => {
  const chats = [
    { key: "claude:chat-b", harness: "claude", title: "Second chat", updatedAt: T0 },
    { key: "claude:chat-a", harness: "claude", title: "First chat", updatedAt: T0 },
  ];
  const order = (device: typeof chats) => recentChatCards([], T0, undefined, device).map((card) => card.title);
  expect(order(chats)).toEqual(["First chat", "Second chat"]);
  expect(order([...chats].reverse())).toEqual(["First chat", "Second chat"]);
});
