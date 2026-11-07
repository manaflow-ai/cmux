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

// Review round 2 (BLOCK at b4208b06), F1: the mic shows only once the host has accepted the
// dictation stream; a host without dictation (it refuses the subscription) shows none.
const { useHostDictation } = await import("../src/pages/home-messages/detail/detailHost");

async function micOffered(subscribe: () => Promise<() => void>): Promise<boolean[]> {
  const container = installDom();
  const seen: boolean[] = [];
  const host = {
    call: async () => ({}),
    subscribe,
    handle: () => () => {},
  };
  function Probe() {
    seen.push(useHostDictation(host as never) !== undefined);
    return null;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Probe />);
  });
  await settle();
  return seen;
}

test("round 2 F1: a host that refuses the dictation stream shows no mic", async () => {
  const seen = await micOffered(() => Promise.reject(new Error("cmux.protocol.unknown_op")));
  expect(seen.length).toBeGreaterThan(0);
  expect(seen.every((offered) => !offered)).toBe(true);
});

test("round 2 F1: a host that accepts the dictation stream shows the mic", async () => {
  const seen = await micOffered(async () => () => {});
  expect(seen[0]).toBe(false);
  expect(seen.at(-1)).toBe(true);
});

// Review round 3 (BLOCK at 814ee903).
const { once, reportedConversation } = await import("../src/pages/home-messages/pageCommands");
const { parseKeptAttachments } = await import("../src/pages/home-messages/host");
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type RecipientDraft = import("../src/pages/home-messages/sheets/recipients").RecipientDraft;

const ada: RecipientDraft = {
  tokens: [{ text: "Ada", recipient: { kind: "contact", contact: { id: "ada", name: "Ada", source: "team" } } }],
  query: "",
};

test("round 3 F1: Escape ends only an empty New Message", () => {
  const nav = new MessagesNav();
  nav.openCompose();
  expect(nav.composeIsEmpty()).toBe(true);
  nav.composeText = "a message with no one yet";
  expect(nav.composeIsEmpty()).toBe(false);
  nav.composeText = "";
  nav.setComposeDraft(ada);
  expect(nav.composeIsEmpty()).toBe(false);
});

test("round 3 F2: the typed text follows the message box to the chosen people's conversation and back", () => {
  const nav = new MessagesNav();
  nav.openCompose();
  nav.composeText = "hello there";
  nav.composeShows("dm_ada");
  expect(nav.draft("dm_ada")).toBe("hello there");
  expect(nav.draftVersion("dm_ada")).toBe(1);
  expect(nav.composeMessage()).toBe("hello there");
  expect(nav.composeIsEmpty()).toBe(false);
  // Ada removed again: the blank page has the text, and her conversation gives it up.
  nav.composeShows(undefined);
  expect(nav.composeText).toBe("hello there");
  expect(nav.draft("dm_ada")).toBe("");
  // A conversation with a draft of its own keeps it; the typed text waits on the blank page.
  nav.keepDraft("dm_bo", "bo's own");
  nav.composeShows("dm_bo");
  expect(nav.draft("dm_bo")).toBe("bo's own");
});

function part(hash: string, name = `${hash}.txt`): HomeAttachment {
  return { type: "attachment", hash, name, mimeType: "text/plain", byteCount: 5 };
}

test("round 3 F3: finished files are kept by the app and come back in their trays on a new page", async () => {
  const kept: Record<string, HomeAttachment[]> = {};
  const saves: { conversation: string; migrated: readonly string[] }[] = [];
  const keeper = {
    load: async () => ({ attachments: structuredClone(kept), legacy: {} }),
    save: (conversation: string, parts: readonly HomeAttachment[], migrated: readonly string[]) => {
      saves.push({ conversation, migrated });
      if (parts.length) kept[conversation] = [...parts];
      else delete kept[conversation];
    },
  };
  const drafts = new AttachmentDrafts(keeper);
  await drafts.load();
  let finish: ((part: HomeAttachment) => void) | undefined;
  const upload = () => new Promise<HomeAttachment>((resolve) => (finish = resolve));
  drafts.add("a", new File(["notes"], "notes.txt"), upload, "failed");
  expect(drafts.holdReason()).toBe("home.uploading");
  expect(kept).toEqual({});
  finish!(part("h1", "notes.txt"));
  await settle();
  expect(kept).toEqual({ a: [part("h1", "notes.txt")] });
  // Kept by the app: a reload no longer has to wait for it.
  expect(drafts.holdReason()).toBeNull();
  const progressSaves = saves.length;
  drafts.patch("a", drafts.files("a")[0]!.id, { thumb: "data:," });
  expect(saves.length).toBe(progressSaves);

  // A relaunch: the new page's tray has the finished file, ready to send.
  const next = new AttachmentDrafts(keeper);
  await next.load();
  expect(next.files("a").map((item) => [item.file.name, item.part?.hash])).toEqual([["notes.txt", "h1"]]);
  next.remove("a", next.files("a")[0]!.id);
  expect(kept).toEqual({});
  expect(
    parseKeptAttachments({ attachments: { a: [part("h1"), { type: "text" }] }, legacy: { b: [{ hash: 1 }] } }),
  ).toEqual({
    attachments: { a: [part("h1")] },
    legacy: {},
  });
});

test("round 3 F3: the native composer's files are uploaded into their trays, and the app lets go of each taken", async () => {
  const saves: { conversation: string; parts: string[]; migrated: readonly string[] }[] = [];
  const keeper = {
    load: async () => ({
      attachments: {},
      legacy: { b: [{ hash: "legacy1", name: "old.txt", mimeType: "text/plain", data: btoa("notes") }] },
    }),
    save: (conversation: string, parts: readonly HomeAttachment[], migrated: readonly string[]) =>
      void saves.push({ conversation, parts: parts.map((p) => p.hash), migrated }),
  };
  const drafts = new AttachmentDrafts(keeper);
  await drafts.load();
  // Nothing uploads before the store can.
  expect(drafts.files("b")).toHaveLength(0);
  const uploaded: { conversation: string; name: string; text: string }[] = [];
  drafts.uploadLegacy(async (conversation, file) => {
    uploaded.push({ conversation, name: file.name, text: await file.text() });
    return part("h2", file.name);
  }, "failed");
  await settle();
  expect(uploaded).toEqual([{ conversation: "b", name: "old.txt", text: "notes" }]);
  expect(drafts.files("b").map((item) => item.part?.hash)).toEqual(["h2"]);
  expect(saves.at(-1)).toEqual({ conversation: "b", parts: ["h2"], migrated: ["legacy1"] });
  // A second store's service uploads nothing again.
  drafts.uploadLegacy(async () => part("h3"), "failed");
  await settle();
  expect(uploaded).toHaveLength(1);
});

test("round 3 F4: a conversation that left the list is not reported as open", () => {
  const listed = new Map([["a", {}]]);
  expect(reportedConversation("a", listed, false)).toBe("a");
  expect(reportedConversation("gone", listed, false)).toBeUndefined();
  expect(reportedConversation("a", listed, true)).toBeUndefined();
});

test("round 3 F5: a request the host asks again runs once", async () => {
  let runs = 0;
  const serve = once(() => ++runs, new Map());
  expect(await serve({ conversation: "a", offset: 1, request: "r1" })).toBe(1);
  expect(await serve({ conversation: "a", offset: 1, request: "r1" })).toBe(1);
  expect(runs).toBe(1);
  expect(await serve({ conversation: "a", offset: 1, request: "r2" })).toBe(2);
  expect(await serve({ conversation: "a", offset: 1 })).toBe(3);
  expect(await serve({ conversation: "a", offset: 1 })).toBe(4);
});

test("round 3 F6: a tapback goes to its part, with its kind", async () => {
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const client = {
    call: async (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      return op === HomeOps.inbox
        ? { me: { id: "me", kind: "human", name: "Me", chief: false }, conversations: [], rev: 1 }
        : {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  await store.reloadInbox();
  const message = { id: "m1", conversation: "a", reactions: [] } as never;
  await store.react(message, "❤️", { partIndex: 2, tapback: "love" });
  const react = calls.find((call) => call.op === HomeOps.react)!;
  expect(react.params).toMatchObject({ partIndex: 2, tapback: "love", value: "❤️", remove: false });
});

// Review round 4 (BLOCK at 530a1236).
const { hostPrepareFile, mayCarryLocation } = await import("../src/pages/home-messages/transcript/prepareAttachment");
const { KeptPendingCarry, parseOutbox } = await import("../src/pages/home-messages/outbox");
type PendingSend = import("../src/pages/home-channels/store").PendingSend;

test("round 4 F1: a photo uploads the bytes the app prepared, location removed", async () => {
  const container = installDom();
  // The tray's local picture is not under test.
  saved.set("FileReader", scope.FileReader);
  scope.FileReader = class {
    readAsDataURL() {}
  };
  const uploaded: string[] = [];
  const service = {
    upload: async (_conversation: string, file: File) => {
      uploaded.push(`${file.name}:${await file.text()}`);
      return part("h1", file.name);
    },
  };
  const prepare = async (file: File) => new File(["no gps"], file.name, { type: file.type });
  let handle: import("../src/pages/home-messages/transcript/MessageComposer").MessageComposerHandle | null = null;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        attachments={{ service: service as never, conversation: "a", prepare }}
        drafts={new AttachmentDrafts()}
        ref={(value) => void (handle = value)}
      />,
    );
  });
  await act(async () => handle!.addFiles([new File(["gps bytes"], "photo.jpg", { type: "image/jpeg" })]));
  await settle();
  expect(uploaded).toEqual(["photo.jpg:no gps"]);
});

test("round 4 F1: the host preparation moves a photo's bytes there and back; other files go as they are", async () => {
  const calls: string[] = [];
  let received = "";
  const client = {
    call: async (op: string, params: Record<string, unknown>) => {
      const name = op.replace("cmux.home.messages.attachments.prepare.", "");
      calls.push(name);
      if (name === "begin") return { id: "s1" };
      if (name === "chunk") received += atob(params.data as string);
      if (name === "finish") return { changed: true, name: "photo.jpg", mimeType: "image/jpeg", byteCount: 5 };
      if (name === "read") return { data: btoa("clean") };
      return null;
    },
  };
  const prepare = hostPrepareFile(client as never);
  const signal = new AbortController().signal;
  const photo = await prepare(new File(["gps bytes"], "photo.jpg", { type: "image/jpeg" }), signal);
  expect(received).toBe("gps bytes");
  expect(await photo.text()).toBe("clean");
  expect(calls).toEqual(["begin", "chunk", "finish", "read", "end"]);
  const notes = new File(["notes"], "notes.txt", { type: "text/plain" });
  calls.length = 0;
  expect(await prepare(notes, signal)).toBe(notes);
  expect(calls).toEqual([]);
  expect(mayCarryLocation(new File(["x"], "clip.mov", { type: "video/quicktime" }))).toBe(true);
  // The setting keeps location: the original goes, and no byte moves.
  const keeping = hostPrepareFile({ call: async () => ({ keep: true }) } as never);
  const original = new File(["gps bytes"], "photo.jpg", { type: "image/jpeg" });
  expect(await keeping(original, signal)).toBe(original);
});

function sendRow(key: string, conversation = "a"): PendingSend {
  return { key, conversation, text: `hello ${key}`, createdAt: 1, failed: false };
}

test("round 4 F2: an unsent send is kept by the app and shows again, not sent, on a new page", async () => {
  const kept: Record<string, PendingSend[]> = {};
  const keeper = {
    load: async () => parseOutbox({ pending: structuredClone(kept) }),
    save: (conversation: string, pending: readonly PendingSend[]) => {
      if (pending.length) kept[conversation] = [...pending];
      else delete kept[conversation];
    },
  };
  const carry = new KeptPendingCarry(keeper);
  await carry.load();
  carry.entries = [sendRow("k1")];
  expect(kept.a?.map((entry) => entry.key)).toEqual(["k1"]);

  // A relaunch: the new page's store shows it as not sent, with its key.
  const next = new KeptPendingCarry(keeper);
  const store = new HomeChannelsStore(null, next);
  expect(store.getSnapshot().pending).toEqual([]);
  await next.load();
  expect(store.getSnapshot().pending.map((entry) => [entry.key, entry.failed])).toEqual([["k1", true]]);
  // Discarded (or delivered): the app lets go of it.
  store.discard("k1");
  expect(kept).toEqual({});
  expect(parseOutbox({ pending: { a: [{ key: 1 }], b: [sendRow("k2", "other")] } })).toEqual([]);
});

function readingClient(reads: unknown[]) {
  const dm = conversation("dm", { lastSeq: 5, unread: 2 });
  const message = { id: "m5", conversation: "dm", seq: 5, author: "ada", createdAt: 1, parts: [], reactions: [] };
  return {
    call: async (op: string, params: unknown) => {
      if (op === HomeOps.read) reads.push(params);
      if (op === HomeOps.inbox)
        return { me: { id: "me", kind: "human", name: "Me", chief: false }, conversations: [dm], rev: 1 };
      if (op === HomeOps.page) return { conversation: dm, messages: [message], hasOlder: false };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

test("round 4 F3: the Messages page reads only what its transcript shows", async () => {
  const reads: unknown[] = [];
  const store = new HomeChannelsStore(readingClient(reads) as never);
  store.readsOnView = true;
  await store.reloadInbox();
  await store.select("dm");
  expect(reads).toEqual([]);
  store.readThrough("dm", 5);
  expect(reads).toMatchObject([{ conversation: "dm", seq: 5 }]);

  // The Channels page still reads by itself (so the test above fails for its own reason).
  const channelReads: unknown[] = [];
  const channels = new HomeChannelsStore(readingClient(channelReads) as never);
  await channels.reloadInbox();
  await channels.select("dm");
  expect(channelReads).toHaveLength(1);
});
