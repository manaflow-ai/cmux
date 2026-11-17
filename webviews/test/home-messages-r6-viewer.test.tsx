// Round 6 of cmux#37736, package viewer: the native picture viewer's rules and component (zoom,
// gallery steps, Compare, marks and undo, Escape's order), View Larger for a video, Reply to
// Selection with its quote card and blockquote send, the host's Reply to Selection command, and
// threads' "N Replies" with nested branch drilling.
import { afterEach, expect, test } from "bun:test";
import { act, useSyncExternalStore } from "react";
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

const model = await import("../src/pages/home-messages/viewer/pictureModel");
const { MediaViewerHost, PictureViewer } = await import("../src/pages/home-messages/viewer/MediaViewer");
const { AttachmentContext, MessageAttachments } = await import("../src/pages/home-channels/AttachmentViews");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { selectionQuote, quotedReply, excerpt } = await import("../src/pages/home-messages/transcript/replyQuote");
const { transcriptRows, timelineReplyCounts } = await import("../src/pages/home-messages/transcript/rows");
const { threadBranch, threadPath } = await import("../src/pages/home-messages/transcript/threadBranch");
const { MessagesNav } = await import("../src/pages/home-messages/nav");
const { servePageCommands, MessagesPageOps } = await import("../src/pages/home-messages/pageCommands");
const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { noMessagesHost } = await import("../src/pages/home-messages/host");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

function picture(name: string, hash: string): HomeAttachment {
  return {
    type: "attachment",
    hash,
    name,
    mimeType: "image/png",
    byteCount: 10,
    width: 400,
    height: 300,
  } as HomeAttachment;
}

const fakeService = {
  image: async (_conversation: string, image: { hash: string }) => `data:image/png;base64,${image.hash}`,
  url: async (_conversation: string, hash: string) => `https://daemon.local/${hash}`,
};

function key(target: EventTarget, key: string, init: Partial<KeyboardEventInit> = {}) {
  return act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

// --- The rules ---

test("viewer keys: arrows step, C compares, Command chords undo, zoom, fit and copy", () => {
  expect(model.viewerKey({ key: "ArrowLeft" })).toBe("left");
  expect(model.viewerKey({ key: "ArrowRight" })).toBe("right");
  expect(model.viewerKey({ key: "c" })).toBe("compare");
  expect(model.viewerKey({ key: "c", metaKey: true })).toBe("copy");
  expect(model.viewerKey({ key: "z", metaKey: true })).toBe("undo");
  expect(model.viewerKey({ key: "=", metaKey: true })).toBe("zoomIn");
  expect(model.viewerKey({ key: "+", metaKey: true })).toBe("zoomIn");
  expect(model.viewerKey({ key: "-", metaKey: true })).toBe("zoomOut");
  expect(model.viewerKey({ key: "0", metaKey: true })).toBe("fit");
  expect(model.viewerKey({ key: "=" })).toBeUndefined();
  expect(model.viewerKey({ key: "z" })).toBeUndefined();
});

test("Escape leaves the words being typed, then the comparison, then closes", () => {
  expect(model.escapeStep({ typing: true, comparing: true })).toBe("text");
  expect(model.escapeStep({ typing: false, comparing: true })).toBe("compare");
  expect(model.escapeStep({ typing: false, comparing: false })).toBe("close");
});

test("gallery steps stop at the ends; a picture compares with the next one, the last with the one before", () => {
  expect(model.steppedIndex(0, -1, 3)).toBe(0);
  expect(model.steppedIndex(2, 1, 3)).toBe(2);
  expect(model.steppedIndex(1, 1, 3)).toBe(2);
  expect(model.comparePartner(0, 3)).toBe(1);
  expect(model.comparePartner(2, 3)).toBe(1);
  expect(model.comparePartner(0, 1)).toBeUndefined();
});

test("zoom fits never above its own size; a double-click goes 1:1 and back; steps stay in 0.05...8", () => {
  expect(model.fitZoom({ width: 400, height: 300 }, { width: 800, height: 600 })).toBe(1);
  expect(model.fitZoom({ width: 1600, height: 600 }, { width: 800, height: 600 })).toBe(0.5);
  expect(model.toggledZoom(0.5, 0.5)).toBe(1);
  expect(model.toggledZoom(1, 0.5)).toBe(0.5);
  expect(model.zoomedIn(7)).toBe(8);
  expect(model.zoomedOut(0.05)).toBe(0.05);
  expect(model.zoomedIn(1)).toBe(1.25);
});

test("marks: a click-sized arrow or box is dropped, undo takes the newest one, files are named as natively", () => {
  expect(model.finishedMark({ kind: "arrow", from: { x: 0, y: 0 }, to: { x: 2, y: 2 } })).toBeUndefined();
  expect(model.finishedMark(model.boxBetween({ x: 10, y: 10 }, { x: 11, y: 40 }))).toBeUndefined();
  expect(model.boxBetween({ x: 40, y: 50 }, { x: 10, y: 10 })).toEqual({
    kind: "box",
    x: 10,
    y: 10,
    width: 30,
    height: 40,
  });
  const markups = new model.PictureMarkups();
  markups.add(0, { kind: "pen", points: [{ x: 1, y: 1 }] });
  markups.add(0, { kind: "text", at: { x: 1, y: 1 }, text: "here" });
  expect(markups.undo(0)).toBe(true);
  expect(markups.of(0).map((mark) => mark.kind)).toEqual(["pen"]);
  expect(markups.undo(1)).toBe(false);
  expect(model.markedFileName("Before · Light", 1700)).toBe("Before-Light-marked-1700.png");
  expect(model.markedFileName("", 5)).toBe("picture-marked-5.png");
  expect(model.savedFileName("shot.png")).toBe("shot-marked.png");
  expect(model.lineWidth({ width: 1500, height: 900 })).toBe(6);
  expect(model.fontSize({ width: 220, height: 220 })).toBe(16);
});

test("the PNG's marks draw as the screen does: an arrow is a shaft and a filled head, text has a halo", () => {
  const calls: string[] = [];
  const ctx = new Proxy(
    {},
    {
      get: (_target, name) =>
        typeof name === "string" &&
        [
          "save",
          "restore",
          "beginPath",
          "moveTo",
          "lineTo",
          "closePath",
          "stroke",
          "fill",
          "strokeRect",
          "strokeText",
          "fillText",
        ].includes(name)
          ? () => calls.push(name)
          : undefined,
      set: () => true,
    },
  ) as never;
  model.drawMarks(ctx, [{ kind: "arrow", from: { x: 0, y: 0 }, to: { x: 100, y: 0 } }], { width: 300, height: 300 });
  expect(calls).toEqual([
    "save",
    "beginPath",
    "moveTo",
    "lineTo",
    "stroke",
    "beginPath",
    "moveTo",
    "lineTo",
    "lineTo",
    "closePath",
    "fill",
    "restore",
  ]);
  calls.length = 0;
  model.drawMarks(ctx, [{ kind: "text", at: { x: 1, y: 1 }, text: "hi" }], { width: 300, height: 300 });
  expect(calls).toEqual(["save", "strokeText", "fillText", "restore"]);
});

// --- The viewer ---

function renderViewer(container: HTMLElement, images: HomeAttachment[], onClose: () => void, index = 0) {
  return act(async () => {
    root = createRoot(container);
    root.render(
      <AttachmentContext.Provider value={fakeService as never}>
        <PictureViewer conversation="c" images={images} initialIndex={index} strings={strings} onClose={onClose} />
      </AttachmentContext.Provider>,
    );
  });
}

test("the viewer steps with the arrows, counts, compares with C and leaves in Escape's order", async () => {
  const container = installDom();
  let closed = 0;
  await renderViewer(container, [picture("a.png", "h1"), picture("b.png", "h2")], () => (closed += 1));
  await settle();
  const viewer = container.querySelector(".mv-viewer")!;
  expect(viewer.querySelector(".mv-counter")?.textContent).toBe("1 of 2");
  await key(viewer, "ArrowRight");
  expect(viewer.querySelector(".mv-counter")?.textContent).toBe("2 of 2");
  await key(viewer, "ArrowRight");
  expect(viewer.querySelector(".mv-counter")?.textContent).toBe("2 of 2");
  await key(viewer, "c");
  expect(viewer.querySelector(".mv-compare")).not.toBeNull();
  await key(viewer, "Escape");
  expect(viewer.querySelector(".mv-compare")).toBeNull();
  expect(closed).toBe(0);
  await key(viewer, "Escape");
  expect(closed).toBe(1);
});

test("a box drag marks the picture, Command-Z undoes it; the text tool's Escape keeps the viewer open", async () => {
  const container = installDom();
  let closed = 0;
  await renderViewer(container, [picture("a.png", "h1")], () => (closed += 1));
  await settle();
  const viewer = container.querySelector(".mv-viewer")!;
  const button = (label: string) => viewer.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;
  const canvas = viewer.querySelector<HTMLElement>(".mv-canvas")!;
  canvas.getBoundingClientRect = () =>
    ({ left: 0, top: 0, width: 400, height: 300, right: 400, bottom: 300 }) as DOMRect;
  await act(async () => button(strings.t("home.picture.tool.box")).click());
  const pointer = (type: string, x: number, y: number) =>
    act(async () => {
      canvas.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, button: 0, clientX: x, clientY: y }));
    });
  expect(button(strings.t("home.picture.undo")).disabled).toBe(true);
  await pointer("pointerdown", 10, 10);
  await pointer("pointermove", 120, 90);
  await pointer("pointerup", 120, 90);
  expect(viewer.querySelectorAll(".mv-marks rect")).toHaveLength(1);
  expect(button(strings.t("home.picture.undo")).disabled).toBe(false);
  await key(viewer, "z", { metaKey: true });
  expect(viewer.querySelectorAll(".mv-marks rect")).toHaveLength(0);
  await act(async () => button(strings.t("home.picture.tool.text")).click());
  await pointer("pointerdown", 30, 30);
  const field = viewer.querySelector<HTMLInputElement>(".mv-text-field")!;
  expect(field).not.toBeNull();
  await key(field, "Escape");
  expect(viewer.querySelector(".mv-text-field")).toBeNull();
  expect(viewer.querySelectorAll(".mv-marks text")).toHaveLength(0);
  expect(closed).toBe(0);
});

test("on the Messages page a picture opens the viewer, not the lightbox; a video's View Larger plays it large", async () => {
  const container = installDom();
  const parts = [
    picture("a.png", "h1"),
    { type: "attachment", hash: "v1", name: "clip.mp4", mimeType: "video/mp4", byteCount: 10 } as HomeAttachment,
  ];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AttachmentContext.Provider value={fakeService as never}>
        <div className="mt-transcript">
          <MediaViewerHost strings={strings} onSend={() => {}}>
            <MessageAttachments conversation="c" parts={parts} strings={strings} />
          </MediaViewerHost>
        </div>
      </AttachmentContext.Provider>,
    );
  });
  await settle();
  await act(async () => container.querySelector<HTMLButtonElement>(".hc-att-image")!.click());
  expect(container.querySelector(".mv-viewer")).not.toBeNull();
  expect(document.querySelector(".hc-lightbox")).toBeNull();
  expect(container.querySelector(`button[aria-label="${strings.t("home.picture.reply")}"]`)).not.toBeNull();
  await key(container.querySelector(".mv-viewer")!, "Escape");
  expect(container.querySelector(".mv-viewer")).toBeNull();
  // The bubble's expand button (the lightbox's on other pages) is View Larger here.
  const larger = container.querySelector<HTMLButtonElement>(".hc-att-video .hc-att-expand")!;
  expect(larger).not.toBeNull();
  await act(async () => larger.click());
  await settle();
  expect(container.querySelector(".mv-video video")?.getAttribute("src")).toBe("https://daemon.local/v1");
  await key(container.querySelector(".mv-video")!, "Escape");
  expect(container.querySelector(".mv-video")).toBeNull();
});

// --- Reply to Selection ---

test("a quote is the selection in one message; across two, or none, there is none; it goes out as a blockquote", () => {
  const container = installDom();
  container.innerHTML =
    '<div data-message="m1"><span>hello there world</span></div><div data-message="m2"><span>other</span></div>';
  const selection = document.getSelection()!;
  const range = document.createRange();
  const first = container.querySelector("[data-message=m1] span")!.firstChild!;
  range.setStart(first, 6);
  range.setEnd(first, 11);
  selection.removeAllRanges();
  selection.addRange(range);
  expect(selectionQuote(document)).toEqual({ message: "m1", text: "there" });
  expect(selectionQuote(document, "m2")).toBeUndefined();
  range.setEnd(container.querySelector("[data-message=m2] span")!.firstChild!, 3);
  selection.removeAllRanges();
  selection.addRange(range);
  expect(selectionQuote(document)).toBeUndefined();
  selection.removeAllRanges();
  expect(selectionQuote(document)).toBeUndefined();
  expect(quotedReply("a\n\nb", "reply")).toBe("> a\n>\n> b\n\nreply");
  expect(excerpt("one  two\nthree", 160)).toBe("one two three");
  expect(excerpt("word ".repeat(60), 20)).toBe("word word word…");
});

test("the host's Reply to Selection reaches the page and answers whether it replied", async () => {
  const nav = new MessagesNav();
  const handlers = new Map<string, (params: unknown) => unknown>();
  const host = {
    call: async () => ({}),
    subscribe: async () => () => {},
    handle: (op: string, run: (params: unknown) => unknown) => {
      handlers.set(op, run);
      return () => handlers.delete(op);
    },
  };
  const stop = servePageCommands(host as never, () => ({ store: {} as never, nav, model: {} as never }));
  expect(await handlers.get(MessagesPageOps.replyToSelection)!({})).toEqual({ replied: false });
  nav.setReplier(() => true);
  expect(await handlers.get(MessagesPageOps.replyToSelection)!({})).toEqual({ replied: true });
  stop();
});

const people = [
  { id: "me", kind: "human", name: "Me", chief: false },
  { id: "ada", kind: "human", name: "Ada", chief: false },
];

function conversation(id: string): HomeConversation {
  return {
    id,
    owner: "local",
    title: id,
    kind: "direct",
    participants: people as never,
    lastSeq: 3,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
}

const at = Date.now() - 60_000;
function message(id: string, seq: number, text: string, patch: Partial<HomeMessage> = {}): HomeMessage {
  return {
    id,
    conversation: "dm",
    seq,
    author: "ada",
    createdAt: at + seq * 1000,
    retracted: false,
    parts: [{ type: "text", text, mentions: [] }],
    reactions: [],
    ...patch,
  } as HomeMessage;
}

/** m1 the root; m2 answers it; m3 answers m2 (a nested branch). */
const tree = [
  message("m1", 1, "root text"),
  message("m2", 2, "a reply", { threadRoot: "m1", replyTo: { message: "m1", partIndex: 0 } }),
  message("m3", 3, "a deeper reply", { threadRoot: "m1", replyTo: { message: "m2", partIndex: 0 } }),
];

function client(sends: Record<string, unknown>[]) {
  const dm = conversation("dm");
  return {
    call: async (op: string, params: Record<string, unknown>) => {
      if (op === HomeOps.send) sends.push(params);
      if (op === HomeOps.inbox) return { me: people[0], conversations: [dm], rev: 1 };
      if (op === HomeOps.page) return { conversation: dm, messages: tree, hasOlder: false };
      if (op === HomeOps.thread)
        return {
          root: tree[0],
          replies: tree.slice(1),
          hasMore: false,
          thread: { root: "m1", replyCount: 2, authors: ["ada"] },
        };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

function Detail({
  store,
  nav,
}: {
  store: InstanceType<typeof HomeChannelsStore>;
  nav: InstanceType<typeof MessagesNav>;
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
      host={null}
      messages={noMessagesHost}
      chrome={{ windowControls: null }}
      nav={nav}
    />
  );
}

async function mount(sends: Record<string, unknown>[]) {
  const container = installDom();
  const store = new HomeChannelsStore(client(sends) as never);
  await store.reloadInbox();
  await store.select("dm");
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(<Detail store={store} nav={nav} />);
  });
  await settle();
  const bubble = (text: string) =>
    [...container.querySelectorAll<HTMLElement>(".mt-text")].find((element) => element.textContent === text);
  return { container, store, nav, bubble };
}

test("Reply to Selection opens the reply with a quote card, and the send carries the quote as a blockquote", async () => {
  const sends: Record<string, unknown>[] = [];
  const { container, store, nav, bubble } = await mount(sends);
  const words = bubble("root text")!.firstChild!;
  const range = document.createRange();
  range.setStart(words, 0);
  range.setEnd(words, 4);
  document.getSelection()!.addRange(range);
  await act(async () => {
    expect(nav.replyToSelection()).toBe(true);
  });
  await settle();
  expect(store.getSnapshot().thread).toBe("m1");
  const card = container.querySelector(".mt-quote-card")!;
  expect(card.querySelector(".mt-quote-title")?.textContent).toBe("Replying to Ada");
  expect(card.querySelector(".mt-quote-words")?.textContent).toBe("root");
  await act(async () => nav.replaceDraft("dm", "hello"));
  await settle();
  await act(async () =>
    container.querySelector<HTMLButtonElement>(`button[aria-label="${strings.t("home.compose.send")}"]`)!.click(),
  );
  await settle();
  expect(sends).toMatchObject([{ conversation: "dm", text: "> root\n\nhello", threadRoot: "m1" }]);
  expect(container.querySelector(".mt-quote-card")).toBeNull();
  // Nothing selected: the command answers no.
  document.getSelection()!.removeAllRanges();
  expect(nav.replyToSelection()).toBe(false);
});

// --- Threads ---

test("the timeline labels a root's replies as natively; the owner's count wins", () => {
  const counts = timelineReplyCounts(tree);
  expect(counts.get("m1")).toBe(2);
  const data = { me: "me", conversation: conversation("dm"), messages: tree, replyCounts: counts };
  const rows = transcriptRows(data, Date.now());
  expect(
    rows.filter((row) => row.kind === "replies").map((row) => [row.key, (row as { count: number }).count]),
  ).toEqual([["replies:m1", 2]]);
  // One reply right under its root shows the thread itself, no label.
  const one = tree.slice(0, 2);
  expect(
    transcriptRows({ ...data, messages: one, replyCounts: timelineReplyCounts(one) }, Date.now()).some(
      (row) => row.kind === "replies",
    ),
  ).toBe(false);
  expect(timelineReplyCounts(one, new Map([["m1", { replyCount: 7 }]])).get("m1")).toBe(7);
});

test("a thread's branch: the drill path, the branch's messages, and its counts", () => {
  expect(threadPath("m3", "m1", tree)).toEqual(["m2", "m3"]);
  expect(threadPath("m1", "m1", tree)).toEqual([]);
  const whole = threadBranch(tree, "m1", []);
  expect(whole.messages.map((m) => m.id)).toEqual(["m1", "m2", "m3"]);
  expect([...whole.counts]).toEqual([["m2", 1]]);
  const branch = threadBranch(tree, "m1", ["m2"]);
  expect(branch.messages.map((m) => m.id)).toEqual(["m2", "m3"]);
  expect([...branch.counts]).toEqual([]);
});

test("N Replies opens the thread, a reply's N Replies drills into its branch, and Back steps out", async () => {
  const { container, store, bubble } = await mount([]);
  const replies = () => [...container.querySelectorAll<HTMLButtonElement>(".mt-replies")];
  expect(replies().map((button) => button.textContent)).toEqual(["2 Replies"]);
  await act(async () => replies()[0]!.click());
  await settle();
  expect(store.getSnapshot().thread).toBe("m1");
  expect(bubble("root text")).toBeDefined();
  expect(replies().map((button) => button.textContent)).toEqual(["1 Reply"]);
  await act(async () => replies()[0]!.click());
  await settle();
  expect(bubble("root text")).toBeUndefined();
  expect(bubble("a reply")).toBeDefined();
  expect(bubble("a deeper reply")).toBeDefined();
  const back = () => container.querySelector<HTMLButtonElement>(".hm-thread-bar button")!;
  await act(async () => back().click());
  await settle();
  expect(bubble("root text")).toBeDefined();
  await act(async () => back().click());
  await settle();
  expect(store.getSnapshot().thread).toBeUndefined();
});
