// The composer's location strip (folder · computer · branch) shows only on a new chat, before its
// first send. Harnesses don't all support changing folder or machine mid-chat, and cmux doesn't
// either, so once the chat has a turn the visible strip is gone, with only a hidden layout slot to
// keep the bottom-anchored composer steady while the first transcript mounts. "First send" is the
// session's own state, never a local flag: a user turn acpmux recorded
// (`turnCount`, or a user row that did not fail), a prompt in flight, a turn running, or a prompt
// waiting in the queue. A reopened chat with history never draws the strip, not even while it
// loads, and a first send that failed (no turn recorded) offers the location again.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { chat, noChat, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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

async function render(snapshot: AcpmuxSnapshot, extra: Record<string, unknown> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        {...extra}
      />,
    ),
  );
}

const strip = () => host.querySelector(".acpmux-composer-strip:not([aria-hidden='true'])");
const placeholder = () => host.querySelector(".acpmux-composer-strip-placeholder");

/// A new chat whose session started (the prewarmed process) and has no turn yet.
function newChat(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return noChat([], {
    sessionId: "new-chat",
    summary: { sessionId: "new-chat", harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
    ...fields,
  });
}

test("a new chat with no turns shows the location strip", async () => {
  await render(newChat());
  expect(strip()).not.toBeNull();
  // A draft chat whose session has not started yet offers it too.
  await render(noChat([], { summary: { sessionId: "", cwd: "/Users/you/src/app" } }));
  expect(strip()).not.toBeNull();
});

test("after the first send the visible strip is gone while its hidden slot keeps the composer anchored", async () => {
  await render(newChat());
  expect(strip()).not.toBeNull();
  expect(placeholder()).toBeNull();
  // The optimistic row of the first prompt (direct.ts `send`): pending, nothing recorded yet.
  await render(newChat({ rows: [{ ...user("Add retries", 1), pending: true }] }));
  expect(strip()).toBeNull();
  expect(placeholder()).not.toBeNull();
  // acpmux took it: one turn, running.
  const running = newChat({ rows: [user("Add retries", 1)], isWorking: true });
  await render({ ...running, summary: { ...running.summary!, turnCount: 1 } });
  expect(strip()).toBeNull();
  expect(placeholder()).not.toBeNull();
  // The turn ended: still a started chat.
  const ended = newChat({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] });
  await render({ ...ended, summary: { ...ended.summary!, turnCount: 1 } });
  expect(strip()).toBeNull();
  expect(placeholder()).not.toBeNull();
});

test("a transient unselected render does not reserve a slot for a reopened chat", async () => {
  // Gallery and pane navigation can render the unselected new-chat state before the selected
  // session arrives. That strip has no session identity, so it must not leave a 46px slot behind
  // once an existing chat with history is attached.
  await render(noChat());
  expect(strip()).not.toBeNull();
  const history = chat([user("Why does the build cache miss on CI?", 30), summary(29, { status: "completed" })]);
  await render({
    ...history,
    sessionId: "old-chat",
    summary: { ...history.summary!, sessionId: "old-chat", turnCount: 4 },
  });
  expect(strip()).toBeNull();
  expect(placeholder()).toBeNull();
});

test("a reopened chat with history never renders the strip, not even while it loads", async () => {
  const drawn: boolean[] = [];
  const observer = new dom.window.MutationObserver(() => drawn.push(strip() !== null));
  observer.observe(host, { childList: true, subtree: true });
  // The pane selected the session; its summary and rows have not arrived yet.
  await render(noChat([], { sessionId: "old-chat" }));
  drawn.push(strip() !== null);
  // The attach landed: the summary with its turns and the history page together.
  const history = chat([user("Why does the build cache miss on CI?", 30), summary(29, { status: "completed" })]);
  await render({
    ...history,
    sessionId: "old-chat",
    summary: { ...history.summary!, sessionId: "old-chat", turnCount: 4 },
  });
  drawn.push(strip() !== null);
  // The session list updates the summary before the attach (direct.ts): no turns known, older history to load.
  await render(noChat([], { sessionId: "older", summary: { sessionId: "older" }, canLoadOlder: true }));
  drawn.push(strip() !== null);
  observer.disconnect();
  expect(drawn.includes(true)).toBe(false);
});

test("a failed first send shows the strip again, so the location can still be picked", async () => {
  await render(newChat());
  expect(strip()).not.toBeNull();
  await render(newChat({ rows: [{ ...user("Add retries", 1), pending: true }] }));
  expect(strip()).toBeNull();
  expect(placeholder()).not.toBeNull();
  // The prompt was refused (direct.ts: `failed`, with Retry); acpmux recorded no turn.
  await render(
    newChat({
      rows: [{ ...user("Add retries", 1), failed: true, error: "Not sent" } as AcpmuxSnapshot["rows"][number]],
    }),
  );
  expect(strip()).not.toBeNull();
  expect(placeholder()).toBeNull();
});

test("a prompt queued before the first turn hides the strip: it runs where the chat is", async () => {
  await render(newChat({ queue: [{ id: "q1", prompt: "Then add a test" }] }));
  expect(strip()).toBeNull();
  expect(placeholder()).toBeNull();
  // The queue paused behind a failed turn still belongs to this location.
  const paused = newChat({ queue: [{ id: "q1", prompt: "Then add a test" }] });
  await render({ ...paused, summary: { ...paused.summary!, queuePaused: true } });
  expect(strip()).toBeNull();
  expect(placeholder()).toBeNull();
});

test("a started chat has no strip, even when its tab's menu offers Move to Cloud or Bring Back Local", async () => {
  // Leo: "egregious amounts of vertical space taken up by absolutely nothing of use". A move lives in
  // the tab's right-click menu; the composer draws no folder · machine band for it.
  const started = newChat({ rows: [user("Add retries", 1), summary(1, { status: "completed" })] });
  const snapshot = { ...started, summary: { ...started.summary!, hostKind: "local" as const, turnCount: 1 } };
  for (const offloads of [["move"], ["bringBack"]]) {
    await render(snapshot, {
      onOffload: () => {},
      offloads,
      onBrowseFolder: async () => "/Users/you/src/other",
    });
    expect(strip()).toBeNull();
    expect(placeholder()).toBeNull();
  }
});

// Leo (2026-10-30): "WHEN I OPEN UP A FUCKING EXISTING TAB I SHOULDN'T FUCKING SEE CHOOSE PROJECT
// CHOOSE ENVIRONMENT AT THE TOP OF THE FFUCKING COMPOSER". An existing tab's page draws its composer
// before the host's handshake answers ("Waiting for the agent service") and before its session
// attaches; that snapshot is empty and looks like a new chat's. The pane knows a chat is new only
// from the handshake (`newSession`) or from the session itself once it arrives.
test("which chats the pane knows enough about to draw the strip for", async () => {
  const { paneKnowsNewChat } = await import("../src/agent-session/acpmux/locationRow");
  const empty = noChat([]);
  // Existing chat, restored or opened: no handshake yet, then a handshake that named its session.
  expect(paneKnowsNewChat({ handshaken: false, newSession: false }, empty)).toBe(false);
  expect(paneKnowsNewChat({ handshaken: true, newSession: false }, empty)).toBe(false);
  // Existing chat attached: its own summary decides (showsLocationRow hides it for its turns).
  expect(paneKnowsNewChat({ handshaken: true, newSession: false }, noChat([], { sessionId: "old-chat" }))).toBe(true);
  // A new chat: the handshake says so. Before it answers, even a new chat is not known yet.
  expect(paneKnowsNewChat({ handshaken: true, newSession: true }, empty)).toBe(true);
  expect(paneKnowsNewChat({ handshaken: false, newSession: true }, empty)).toBe(false);
});

test("an existing chat never shows the new chat's project and environment strip, not even while it loads", async () => {
  const drawn: boolean[] = [];
  const observer = new dom.window.MutationObserver(() => drawn.push(strip() !== null));
  observer.observe(host, { childList: true, subtree: true });
  // Opening the tab: the agent service has not answered, the snapshot is empty.
  await render(noChat([]), { chatKnown: false });
  drawn.push(strip() !== null);
  // The handshake named the session; it is still loading.
  await render(noChat([], { sessionId: "old-chat" }), { chatKnown: true });
  drawn.push(strip() !== null);
  // It attached, with its history.
  const history = chat([user("Why does the build cache miss on CI?", 30), summary(29, { status: "completed" })]);
  await render(
    { ...history, sessionId: "old-chat", summary: { ...history.summary!, sessionId: "old-chat", turnCount: 4 } },
    { chatKnown: true },
  );
  drawn.push(strip() !== null);
  observer.disconnect();
  expect(drawn.includes(true)).toBe(false);
  expect(placeholder()).toBeNull();
});

test("a new empty chat the handshake named shows the strip", async () => {
  await render(noChat([]), { chatKnown: true });
  expect(strip()).not.toBeNull();
  await render(newChat(), { chatKnown: true });
  expect(strip()).not.toBeNull();
});
