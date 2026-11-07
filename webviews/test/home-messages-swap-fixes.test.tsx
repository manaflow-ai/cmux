// The fixes of cmux#37736's first review (BLOCK at c3dd70eb): what the Messages page tells the app
// while New Message shows (F1), its composer drafts kept across reconnects and launches (F2), its
// attached files kept per conversation (F3), the conversations deleted from the list (F4), the
// page's keyboard handed to the message box (F5), and no Chief opened by the page itself before
// the app picks the preferred one (C1).
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { AttachmentDrafts } = await import("../src/pages/home-messages/transcript/attachmentDrafts");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { MessagesNav, DRAFT_SAVE_DELAY_MS } = await import("../src/pages/home-messages/nav");
const { followPageFocus, selectedPayload } = await import("../src/pages/home-messages/pageCommands");
const { visibleConversations } = await import("../src/pages/home-messages/list/model");
const { parseHidden, parseDrafts } = await import("../src/pages/home-messages/host");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

function conversation(id: string, patch: Partial<HomeConversation> = {}): HomeConversation {
  return {
    id,
    owner: "local",
    title: id,
    kind: "direct",
    participants: [],
    lastSeq: 5,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    ...patch,
  };
}

test("F1: New Message tells the app it composes, not that nothing shows", () => {
  expect(selectedPayload({ conversation: "a" }, true)).toEqual({ conversation: null, composing: true });
  expect(selectedPayload(null, false)).toEqual({ conversation: null });
  expect(selectedPayload({ conversation: "a", message: "m" }, false)).toEqual({ conversation: "a", message: "m" });
});

test("F2: drafts go to the app's keeper after a pause and come back on a new page", async () => {
  const kept: Record<string, string> = {};
  const keeper = {
    load: async () => ({ ...kept }),
    save: (conversation: string, text: string) => {
      if (text) kept[conversation] = text;
      else delete kept[conversation];
    },
  };
  jest.useFakeTimers();
  const nav = new MessagesNav(keeper);
  nav.keepDraft("a", "half a thought");
  expect(kept).toEqual({});
  jest.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
  jest.useRealTimers();
  expect(kept).toEqual({ a: "half a thought" });
  nav.keepDraft("a", "");
  nav.keepDraft("b", "other");
  nav.flushDrafts();
  expect(kept).toEqual({ b: "other" });

  // A relaunch: a new page reads what was kept, and the composer of "b" starts again with it.
  const next = new MessagesNav(keeper);
  next.keepDraft("c", "typed before the read");
  await next.loadDrafts();
  expect(next.draft("b")).toBe("other");
  expect(next.draftVersion("b")).toBe(1);
  expect(next.draft("c")).toBe("typed before the read");
  expect(parseDrafts({ a: "x", b: 3, c: "" })).toEqual({ a: "x" });
});

test("F3: a file attached in one conversation is there again after another one showed", async () => {
  const container = installDom();
  const drafts = new AttachmentDrafts();
  let finish: (() => void) | undefined;
  let aborted = false;
  const service = {
    upload: (_conversation: string, file: File, _progress: unknown, signal: AbortSignal) =>
      new Promise((resolve) => {
        signal.addEventListener("abort", () => (aborted = true));
        finish = () =>
          resolve({ type: "attachment", hash: "h1", name: file.name, mimeType: "text/plain", byteCount: file.size });
      }),
  };
  let handle: import("../src/pages/home-messages/transcript/MessageComposer").MessageComposerHandle | null = null;
  const render = (id: string) =>
    root!.render(
      <MessageComposer
        key={id}
        strings={strings}
        sendEnabled
        onSend={async () => true}
        attachments={{ service: service as never, conversation: id }}
        drafts={drafts}
        ref={(value) => void (handle = value)}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    render("a");
  });
  await act(async () => handle!.addFiles([new File(["notes"], "notes.txt", { type: "text/plain" })]));
  await settle();
  expect(container.querySelectorAll(".hc-tray-item")).toHaveLength(1);
  // Another conversation shows: its tray is empty, and the upload of "a" goes on.
  await act(async () => render("b"));
  await settle();
  expect(container.querySelectorAll(".hc-tray-item")).toHaveLength(0);
  expect(aborted).toBe(false);
  await act(async () => finish!());
  await settle();
  await act(async () => render("a"));
  await settle();
  expect(container.querySelectorAll(".hc-tray-item.done")).toHaveLength(1);
});

test("F4: a deleted conversation stays off the list until a newer message", () => {
  const conversations = new Map([
    ["a", conversation("a", { lastSeq: 5 })],
    ["b", conversation("b", { lastSeq: 9 })],
  ]);
  const hidden = parseHidden({ hidden: { a: 5, b: 7, junk: "x" } });
  expect([...hidden]).toEqual([
    ["a", 5],
    ["b", 7],
  ]);
  expect([...visibleConversations(conversations, hidden).keys()]).toEqual(["b"]);
  expect(visibleConversations(conversations, new Map())).toBe(conversations);
});

test("F5: the page getting the keyboard hands it to the message box", () => {
  const target = new EventTarget();
  const doc = { activeElement: null as Element | null, body: {} as HTMLElement };
  let focused = 0;
  const stop = followPageFocus(target as never, doc as never, { focus: () => (focused++, true) });
  target.dispatchEvent(new Event("focus"));
  expect(focused).toBe(1);
  // A field in the page already has it: it keeps it.
  doc.activeElement = {} as Element;
  target.dispatchEvent(new Event("focus"));
  expect(focused).toBe(1);
  stop();
  doc.activeElement = null;
  target.dispatchEvent(new Event("focus"));
  expect(focused).toBe(1);
});

test("C1: the page opens no Chief by itself on its first load; a reconnect reopens what showed", async () => {
  const nav = new MessagesNav();
  const chief = conversation("chief", { kind: "chief" });
  const dm = conversation("dm");
  expect(nav.restorable([chief, dm])).toBeUndefined();
  nav.lastShown = "dm";
  expect(nav.restorable([chief, dm])).toBe("dm");
  expect(nav.restorable([chief])).toBeUndefined();

  const client = {
    call: async (op: string) =>
      op === HomeOps.inbox
        ? { me: { id: "me", kind: "human", name: "Me", chief: false }, conversations: [chief, dm], rev: 1 }
        : {},
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  store.pickDefault = (list) => new MessagesNav().restorable(list);
  await store.reloadInbox();
  expect(store.getSnapshot().conversations.size).toBe(2);
  expect(store.getSnapshot().selected).toBeUndefined();
});
