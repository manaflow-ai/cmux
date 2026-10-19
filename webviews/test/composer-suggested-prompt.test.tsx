// An idle new chat's empty prompt suggests the open PR another chat in this checkout made, and Tab
// takes it (Leo 2026-10-18): "Fix the failing checks on PR #123", "Finish draft PR #123: <title>"
// or "Continue PR #123: <title>". Only PRs, because a fresh agent can act on one with gh; nothing
// from a different checkout or branch, nothing a chat is already working on, nothing older than
// three days. Tab writes it and never sends; Esc puts it away for this chat.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, session, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { AcpmuxSessionEntry, SessionPullRequest } from "../src/agent-session/acpmux/sessionList";

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
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

async function render(snapshot: AcpmuxSnapshot) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => {
          sent += 1;
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: APP, label: "app" }]}
      />,
    ),
  );
}

let sent = 0;
const APP = "/Users/you/src/app";
const shown = () => host.querySelector(".acpmux-md-placeholder")?.textContent;
const key = () => host.querySelector(".acpmux-md-placeholder-key")?.textContent;
const field = () => host.querySelector<HTMLElement>(".acpmux-md")!;
const press = (name: string, init: KeyboardEventInit = {}) =>
  act(async () => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init }),
    );
  });

const recent = Date.now() - 60 * 60 * 1000;
const prChat = (fields: Partial<AcpmuxSessionEntry> = {}, pr: Partial<SessionPullRequest> = {}) =>
  session({
    sessionId: "older",
    cwd: APP,
    updatedAt: recent,
    turnCount: 4,
    pullRequest: {
      number: 123,
      title: "Retry failed uploads",
      state: "open",
      checks: "passing",
      ...pr,
    } as SessionPullRequest,
    ...fields,
  });
/** A fresh chat in APP (a folder picked, no session yet) beside `sessions`. */
const fresh = (sessions: AcpmuxSessionEntry[]) => noChat(sessions, { summary: { sessionId: "", cwd: APP } as never });

test("an open PR from another chat here is suggested, with a Tab keycap", async () => {
  await render(fresh([prChat()]));
  expect(shown()).toBe("Continue PR #123: Retry failed uploadsTab");
  expect(key()).toBe("Tab");
});

test("failing checks and drafts get their own wording", async () => {
  await render(fresh([prChat({}, { checks: "failing" })]));
  expect(shown()).toStartWith("Fix the failing checks on PR #123");
  await render(fresh([prChat({}, { state: "draft", checks: "pending" })]));
  expect(shown()).toStartWith("Finish draft PR #123: Retry failed uploads");
});

test("nothing is suggested from another folder, another worktree, a merged PR, an old chat or a busy one", async () => {
  for (const sessions of [
    [prChat({ cwd: "/Users/you/src/other" })],
    [prChat({ worktree: "/Users/you/src/app-wt" })],
    [prChat({}, { state: "merged" })],
    [prChat({ updatedAt: Date.now() - 4 * 24 * 60 * 60 * 1000 })],
    [prChat({ indicator: "working" })],
    [prChat(), prChat({ sessionId: "busy", indicator: "input" })],
    [prChat({ archived: true })],
  ]) {
    await render(fresh(sessions));
    expect(shown()).toBe("Do anything");
    expect(key()).toBeUndefined();
  }
});

test("a chat that knows its branch takes no PR from another branch", async () => {
  // A session started before its first prompt (a New Tab chip pick) knows its branch.
  const started = (sessions: AcpmuxSessionEntry[]) =>
    noChat(sessions, {
      sessionId: "new",
      summary: { sessionId: "new", cwd: APP, branch: "main", turnCount: 0 } as never,
    });
  await render(started([prChat({ branch: "leo/retries" })]));
  expect(shown()).toBe("Do anything");
  await render(started([prChat({ branch: "main" })]));
  expect(shown()).toStartWith("Continue PR #123");
});

test("a chat with turns gets no suggestion", async () => {
  await render(
    noChat([prChat()], {
      sessionId: "chat",
      summary: { sessionId: "chat", cwd: APP, turnCount: 1 } as never,
      rows: [user("Hi", 1)],
    }),
  );
  expect(shown()).toBe("Do anything");
});

test("Tab writes the suggestion without sending; Shift-Tab does not take it; Esc puts it away", async () => {
  sent = 0;
  await render(fresh([prChat()]));
  await press("Tab", { shiftKey: true });
  expect(field().textContent).toBe("");
  await press("Tab");
  expect(field().textContent).toBe("Continue PR #123: Retry failed uploads");
  expect(sent).toBe(0);

  act(() => root?.unmount());
  root = undefined;
  await render(fresh([prChat()]));
  await press("Escape");
  expect(shown()).toBe("Do anything");
  await press("Tab");
  expect(field().textContent).toBe("");
});
