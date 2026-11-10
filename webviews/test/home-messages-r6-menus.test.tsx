// Review round 6 of cmux#37736, package "menus": a transcript bubble's right-click menu matches the
// native transcript's (MessagesLabHome PaneMenu.swift): its order, Delete on my message to a Chief
// (F4, optimistic, a refusal brings it back), Retry Reply, Copy of the selected words, Copy Link in
// the build's scheme, Tapback Details…, Attach Sticker…, Forward…, Share…, the link and file rows.
import { afterEach, expect, test } from "bun:test";
import { act, useSyncExternalStore } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

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

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { MessagesNav } = await import("../src/pages/home-messages/nav");
const { noMessagesHost } = await import("../src/pages/home-messages/host");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { bubbleMenuItems, canDeleteMessage, canRetryReply, NO_BUBBLE_HOST } =
  await import("../src/pages/home-messages/transcript/bubbleMenu");
const { readPointer } = await import("../src/pages/home-messages/transcript/TranscriptRows");
const { parseBubbleFacts, DetailOps } = await import("../src/pages/home-messages/detail/detailHost");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;
type BubbleContext = import("../src/pages/home-messages/transcript/bubbleMenu").BubbleContext;
type TranscriptRow = import("../src/pages/home-messages/transcript/rows").TranscriptRow;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

const people = [
  { id: "me", kind: "human", name: "Me", chief: false },
  { id: "chief", kind: "agent", name: "Chief", chief: true },
];

function conversation(id: string, patch: Partial<HomeConversation> = {}): HomeConversation {
  return {
    id,
    owner: "local",
    title: id,
    kind: "chief",
    participants: people as never,
    lastSeq: 2,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    ...patch,
  };
}

function message(patch: Partial<HomeMessage> = {}): HomeMessage {
  return {
    id: "m1",
    conversation: "c",
    seq: 1,
    author: "me",
    createdAt: Date.now() - 60_000,
    retracted: false,
    parts: [{ type: "text", text: "hello there", mentions: [] }],
    reactions: [],
    ...patch,
  };
}

function bubble(patch: Partial<HomeMessage> = {}): Extract<TranscriptRow, { kind: "bubble" }> {
  const m = message(patch);
  return {
    kind: "bubble",
    key: `part:${m.id}:0`,
    gap: 0,
    message: m,
    parts: m.parts,
    partIndex: 0,
    outgoing: m.author === "me",
    tail: true,
    indent: false,
    reactions: m.reactions,
    markdown: false,
  };
}

const ALL_HOST = { linkScheme: "cmux-dev-menus", forward: true, share: true, retryReply: true, files: true };

function context(patch: Partial<BubbleContext> = {}): BubbleContext {
  return {
    me: "me",
    conversation: conversation("c"),
    online: true,
    typing: false,
    host: ALL_HOST,
    ...patch,
  };
}

const every = {
  onRetry() {},
  onDiscard() {},
  onReact() {},
  onCopy() {},
  onReply() {},
  onOpenLink() {},
  onDelete() {},
  onRetryReply() {},
  onForward() {},
  onShare() {},
  onFile() {},
  onTapbackDetails() {},
  onSticker() {},
  onVideo() {},
};

test("the menu is in the native order: tapbacks, Tapback Details…, Reply…, Attach Sticker…; Copy, Copy Link, Forward…; Retry Reply; Share…; Delete", () => {
  const items = bubbleMenuItems(bubble(), {}, context(), every, strings);
  expect(items.map((item) => item.id)).toEqual([
    "tapback.love",
    "tapback.like",
    "tapback.dislike",
    "tapback.laugh",
    "tapback.emphasize",
    "tapback.question",
    "tapbackDetails",
    "reply",
    "sticker",
    "copy",
    "copyLink",
    "forward",
    "retryReply",
    "share",
    "delete",
  ]);
  // Separators between the groups, as the native menu draws them.
  const separated = items.filter((item) => item.separatorBefore).map((item) => item.id);
  expect(separated).toEqual(["tapbackDetails", "copy", "retryReply", "share", "delete"]);
  expect(items.find((item) => item.id === "delete")?.destructive).toBe(true);
});

test("F4: Delete only on my committed message in a one-to-one Chief chat, online, not an agent's send", () => {
  expect(canDeleteMessage(bubble(), context())).toBe(true);
  expect(canDeleteMessage(bubble(), context({ conversation: conversation("c", { kind: "direct" }) }))).toBe(false);
  expect(canDeleteMessage(bubble(), context({ conversation: conversation("c", { kind: "group" }) }))).toBe(false);
  expect(canDeleteMessage(bubble({ author: "chief" }), context())).toBe(false);
  expect(canDeleteMessage(bubble({ id: "pending:k1" }), context())).toBe(false);
  expect(canDeleteMessage(bubble({ retracted: true }), context())).toBe(false);
  expect(canDeleteMessage(bubble({ clientMessageId: "agent~123" }), context())).toBe(false);
  expect(canDeleteMessage(bubble(), context({ online: false }))).toBe(false);
  expect(canDeleteMessage(bubble({ parts: [{ type: "work", title: "run", status: "done" }] }), context())).toBe(false);
});

test("Retry Reply: my committed message to a Chief whose brain takes it, while nobody types", () => {
  expect(canRetryReply(bubble(), context())).toBe(true);
  expect(canRetryReply(bubble(), context({ typing: true }))).toBe(false);
  expect(canRetryReply(bubble(), context({ host: { ...ALL_HOST, retryReply: false } }))).toBe(false);
  expect(canRetryReply(bubble({ author: "chief" }), context())).toBe(false);
  expect(canRetryReply(bubble(), context({ conversation: conversation("c", { kind: "direct" }) }))).toBe(false);
  // My failed send has Try Again and Delete instead.
  const failed = { ...bubble({ id: "pending:k1", seq: 0 }), delivery: { state: "failed" } } as never;
  const ids = bubbleMenuItems(failed, {}, context(), every, strings).map((item) => item.id);
  expect(ids).toContain("retry");
  expect(ids).toContain("discard");
  expect(ids).not.toContain("retryReply");
});

test("Copy copies the words selected in the bubble, else the whole part", () => {
  const copied: string[] = [];
  const actions = { ...every, onCopy: (text: string) => copied.push(text) };
  bubbleMenuItems(bubble(), {}, context(), actions, strings)
    .find((item) => item.id === "copy")!
    .onSelect();
  bubbleMenuItems(bubble(), { selection: "there" }, context(), actions, strings)
    .find((item) => item.id === "copy")!
    .onSelect();
  expect(copied).toEqual(["hello there", "there"]);
});

test("Copy Link copies the message's permalink in the build's scheme; no scheme, no Copy Link", () => {
  const copied: string[] = [];
  const actions = { ...every, onCopy: (text: string) => copied.push(text) };
  bubbleMenuItems(bubble(), {}, context(), actions, strings)
    .find((item) => item.id === "copyLink")!
    .onSelect();
  expect(copied).toEqual(["cmux-dev-menus://conversation/c/message/m1"]);
  const bare = bubbleMenuItems(bubble(), {}, context({ host: NO_BUBBLE_HOST }), actions, strings).map((i) => i.id);
  expect(bare).not.toContain("copyLink");
  expect(bare).not.toContain("forward");
  expect(bare).not.toContain("share");
  expect(bare).not.toContain("retryReply");
});

test("a link under the pointer leads with Open Link and Copy Link Address; a path link with the file rows", () => {
  const link = bubbleMenuItems(bubble(), { href: "https://example.com" }, context(), every, strings);
  expect(link.slice(0, 2).map((item) => item.id)).toEqual(["link.open", "link.copy"]);
  const path = bubbleMenuItems(bubble(), { path: "/tmp/a.md" }, context(), every, strings);
  expect(path.slice(0, 5).map((item) => item.id)).toEqual([
    "path.open",
    "path.openWith",
    "path.quickLook",
    "path.reveal",
    "path.copyPath",
  ]);
  const files: unknown[] = [];
  bubbleMenuItems(
    bubble(),
    { path: "/tmp/a.md" },
    context(),
    { ...every, onFile: (...a: unknown[]) => files.push(a) },
    strings,
  )
    .find((item) => item.id === "path.reveal")!
    .onSelect();
  expect(files).toEqual([["reveal", { path: "/tmp/a.md" }]]);
});

test("an attachment has Copy, Save As… and the file rows; a video Play and View Larger", () => {
  const video = {
    type: "attachment" as const,
    hash: "h1",
    name: "clip.mp4",
    mimeType: "video/mp4",
    byteCount: 10,
  };
  const row = bubble({ parts: [video] });
  const ids = bubbleMenuItems(row, { attachment: video, video: { playing: false } }, context(), every, strings).map(
    (item) => item.id,
  );
  expect(ids).toEqual(
    expect.arrayContaining([
      "video.toggle",
      "video.larger",
      "attachment.copy",
      "attachment.saveAs",
      "attachment.open",
      "attachment.openWith",
      "attachment.reveal",
    ]),
  );
  expect(ids.indexOf("video.toggle")).toBeLessThan(ids.indexOf("attachment.copy"));
  const playing = bubbleMenuItems(row, { attachment: video, video: { playing: true } }, context(), every, strings);
  expect(playing.find((item) => item.id === "video.toggle")?.label).toBe(strings.t("home.video.pause"));
});

test("readPointer reads the link, the path link and the words selected in the bubble", () => {
  installDom();
  document.body.innerHTML =
    '<div id="b"><span id="t">hello there</span> <a id="w" href="https://example.com">x</a> <a id="f" href="file:///tmp/a%20b.md">f</a></div><p id="o">outside</p>';
  const box = document.getElementById("b")!;
  expect(readPointer(document.getElementById("w"), box, []).pointer).toEqual({ href: "https://example.com" });
  expect(readPointer(document.getElementById("f"), box, []).pointer).toEqual({ path: "/tmp/a b.md" });
  const text = document.getElementById("t")!.firstChild!;
  const range = document.createRange();
  range.setStart(text, 6);
  range.setEnd(text, 11);
  window.getSelection()!.removeAllRanges();
  window.getSelection()!.addRange(range);
  expect(readPointer(text.parentElement, box, []).pointer).toEqual({ selection: "there" });
  // A selection outside this bubble is not its Copy.
  const outside = document.getElementById("o")!.firstChild!;
  range.setStart(outside, 0);
  range.setEnd(outside, 3);
  expect(readPointer(text.parentElement, box, []).pointer).toEqual({});
});

test("parseBubbleFacts keeps only a cmux scheme and true flags", () => {
  expect(
    parseBubbleFacts({ linkScheme: "cmux-dev-x", forward: true, share: 1, retryReply: true, files: false }),
  ).toEqual({ linkScheme: "cmux-dev-x", forward: true, share: false, retryReply: true, files: false });
  expect(parseBubbleFacts({ linkScheme: "javascript" }).linkScheme).toBeUndefined();
  expect(parseBubbleFacts(null)).toEqual(NO_BUBBLE_HOST);
});

/** A Chief chat with my message and the Chief's reply; `refuse` makes the owner refuse a retract. */
function chiefClient(calls: { op: string; params: unknown }[], options: { refuse?: boolean } = {}) {
  const chat = conversation("c");
  const at = Date.now() - 60_000;
  const mine = message({ createdAt: at, reactions: [{ author: "chief", partIndex: 0, value: "👍", tapback: "like" }] });
  const reply = message({
    id: "m2",
    seq: 2,
    author: "chief",
    createdAt: at + 1000,
    parts: [{ type: "text", text: "a reply", mentions: [] }],
  });
  let release: (() => void) | undefined;
  return {
    release: () => release?.(),
    client: {
      call: async (op: string, params: unknown) => {
        calls.push({ op, params });
        if (op === HomeOps.inbox) return { me: people[0], conversations: [chat], rev: 1 };
        if (op === HomeOps.page) return { conversation: chat, messages: [mine, reply], hasOlder: false };
        if (op === HomeOps.retract) {
          await new Promise<void>((resolve) => (release = resolve));
          if (options.refuse) throw new Error("refused");
          return {};
        }
        if (op === DetailOps.bubbleFacts) return ALL_HOST;
        return {};
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    },
  };
}

function Detail({
  store,
  nav,
  host,
}: {
  store: InstanceType<typeof HomeChannelsStore>;
  nav: InstanceType<typeof MessagesNav>;
  host: never;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const open = snapshot.selected ? snapshot.conversations.get(snapshot.selected) : undefined;
  return (
    <MessagesDetail
      store={store}
      snapshot={snapshot}
      conversation={open}
      me={snapshot.me}
      strings={strings}
      host={host}
      messages={noMessagesHost}
      chrome={{ windowControls: null }}
      nav={nav}
    />
  );
}

async function mount(options: { refuse?: boolean } = {}) {
  const container = installDom();
  const calls: { op: string; params: unknown }[] = [];
  const fake = chiefClient(calls, options);
  const store = new HomeChannelsStore(fake.client as never);
  await store.reloadInbox();
  await store.select("c");
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(<Detail store={store} nav={nav} host={fake.client as never} />);
  });
  await settle();
  const text = (value: string) =>
    [...container.querySelectorAll<HTMLElement>(".mt-text")].find((element) => element.textContent === value);
  const rightClick = (element: Element) =>
    act(async () => {
      element.dispatchEvent(
        new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
      );
    });
  const item = (label: string) =>
    [...document.querySelectorAll<HTMLElement>('[role="menuitem"], [role="menuitemcheckbox"]')].find(
      (entry) => entry.textContent === label,
    );
  return { container, calls, store, fake, text, rightClick, item };
}

test("F4: Delete on my message to a Chief retracts it at once; the owner's answer keeps it gone", async () => {
  const { calls, store, fake, text, rightClick, item } = await mount();
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("home.menu.deleteMessage"))!.click());
  // Gone before the owner answers.
  expect(store.getSnapshot().messages.find((m) => m.id === "m1")?.retracted).toBe(true);
  expect(text("hello there")).toBeUndefined();
  expect(calls.find((call) => call.op === HomeOps.retract)?.params).toMatchObject({ conversation: "c", message: "m1" });
  // The Chief's reply has no Delete (not mine).
  await rightClick(document.querySelector('[data-message="m2"]')!);
  expect(item(strings.t("home.menu.deleteMessage"))).toBeUndefined();
  await act(async () => fake.release());
  await settle();
  expect(store.getSnapshot().messages.find((m) => m.id === "m1")?.retracted).toBe(true);
});

test("F4: a refused Delete brings the message back", async () => {
  const { store, fake, text, rightClick, item } = await mount({ refuse: true });
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("home.menu.deleteMessage"))!.click());
  expect(text("hello there")).toBeUndefined();
  await act(async () => fake.release());
  await settle();
  const back = store.getSnapshot().messages.find((m) => m.id === "m1");
  expect(back?.retracted).toBe(false);
  expect(back?.parts).toEqual([{ type: "text", text: "hello there", mentions: [] }]);
  expect(text("hello there")).toBeDefined();
});

test("Retry Reply, Forward… and Share… go to the host with the message", async () => {
  const { calls, text, rightClick, item } = await mount();
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("home.menu.retryReply"))!.click());
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("home.menu.forward"))!.click());
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("menu.share"))!.click());
  await settle();
  expect(
    calls.filter((call) => call.op.startsWith("cmux.home.messages.bubble.") && call.op !== DetailOps.bubbleFacts),
  ).toEqual([
    { op: DetailOps.bubbleRetryReply, params: { conversation: "c", message: "m1" } },
    { op: DetailOps.bubbleForward, params: { text: "hello there" } },
    { op: DetailOps.bubbleShare, params: { text: "hello there" } },
  ]);
});

test("Tapback Details… lists each reaction's emoji and person", async () => {
  const { text, rightClick, item } = await mount();
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("menu.tapbackDetails"))!.click());
  await settle();
  const details = document.querySelector(".mt-tapback-details");
  expect(details?.textContent).toContain(strings.t("tapback.details.title"));
  expect(details?.querySelector("li")?.textContent).toBe("👍  Chief");
});

test("Attach Sticker… opens the emoji picker, and its emoji goes on the message as a reaction", async () => {
  const { calls, text, rightClick, item } = await mount();
  await rightClick(text("hello there")!);
  await act(async () => item(strings.t("menu.attachSticker"))!.click());
  // The emoji table loads on the first open: wait for its first cell.
  for (let turn = 0; turn < 200 && !document.querySelector(".hc-emoji-cell"); turn += 1) await settle();
  expect(document.querySelector(".hc-emoji-search")).not.toBeNull();
  const first = document.querySelector<HTMLButtonElement>(".hc-emoji-cell")!;
  const value = first.textContent;
  await act(async () => first.click());
  await settle();
  const react = calls.find((call) => call.op === HomeOps.react)?.params as Record<string, unknown> | undefined;
  expect(react).toMatchObject({ conversation: "c", message: "m1", partIndex: 0, value, remove: false });
  expect(react?.tapback).toBeUndefined();
  expect(document.querySelector(".hc-emoji-search")).toBeNull();
});

test("Cancel Upload follows the native order: Try Again on a failed send, else Retry Reply, else Cancel Upload", () => {
  const sending = { ...bubble({ id: "pending:k2", seq: 0 }), delivery: { state: "sending" } } as never;
  const cancels: string[] = [];
  const actions = {
    ...every,
    canCancelUpload: (key: string) => key === "k2",
    onCancelUpload: (key: string) => cancels.push(key),
  };
  const items = bubbleMenuItems(sending, {}, context(), actions, strings);
  const ids = items.map((item) => item.id);
  expect(ids).toContain("cancelUpload");
  expect(ids).not.toContain("retry");
  expect(ids).not.toContain("delete");
  items.find((item) => item.id === "cancelUpload")!.onSelect();
  expect(cancels).toEqual(["k2"]);
  const failed = { ...bubble({ id: "pending:k2", seq: 0 }), delivery: { state: "failed" } } as never;
  expect(bubbleMenuItems(failed, {}, context(), actions, strings).map((item) => item.id)).not.toContain("cancelUpload");
});

test("Copy copies a link card's address (bubbleCopyText), and selected words still win; no Forward on a card", () => {
  const copied: string[] = [];
  const actions = { ...every, onCopy: (text: string) => copied.push(text) };
  const card = bubble({ parts: [{ type: "link_preview", url: "https://example.com/a" } as never] });
  const items = bubbleMenuItems(card, {}, context(), actions, strings);
  items.find((item) => item.id === "copy")!.onSelect();
  expect(items.map((item) => item.id)).not.toContain("forward");
  bubbleMenuItems(card, { selection: "example" }, context(), actions, strings)
    .find((item) => item.id === "copy")!
    .onSelect();
  expect(copied).toEqual(["https://example.com/a", "example"]);
});
