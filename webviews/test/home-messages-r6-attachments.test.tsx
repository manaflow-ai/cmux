// Round 6 (attachments) of cmux#37736: a kept file keeps its bytes across a relaunch and goes up
// again when the owner let go of its upload (F1, as HomeStore's draft attachments kept theirs in
// the blob cache), a file dropped on the conversation list goes to the shown conversation
// (HomeSidebarSplitView+Drop.swift), and a send still uploading can be cancelled from its menu
// (MessagesLab PaneMenu's Cancel Upload).
import { afterEach, expect, test } from "bun:test";
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
  const keys = [
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
  ];
  for (const key of keys) saved.set(key, scope[key]);
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

const { AttachmentDrafts, REFRESH_AFTER_MS } = await import("../src/pages/home-messages/transcript/attachmentDrafts");
const { parseKeptAttachments, noMessagesHost } = await import("../src/pages/home-messages/host");
const { MessagesNav } = await import("../src/pages/home-messages/nav");
const { MessagesApp } = await import("../src/pages/home-messages/App");
const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { pageError } = await import("../src/pages/shared/pageClient");
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type KeptAttachments = import("../src/pages/home-messages/transcript/attachmentDrafts").KeptAttachments;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

function part(hash: string, byteCount = 5, name = "notes.txt"): HomeAttachment {
  return { type: "attachment", hash, name, mimeType: "text/plain", byteCount };
}

/** The app's book (HomeMessagesAttachmentDrafts.swift): entries by hash, and each one's bytes. */
function book(kept: KeptAttachments = { attachments: {}, legacy: {} }) {
  const bytes = new Map<string, Blob>();
  const keeper = {
    load: async () => kept,
    put: () => {},
    remove: (_conversation: string, hash: string) => void bytes.delete(hash),
    release: () => {},
    write: async (hash: string, file: Blob) => {
      bytes.set(hash, file);
      return true;
    },
    read: async (kept: HomeAttachment) => {
      const blob = bytes.get(kept.hash);
      return blob ? new File([blob], kept.name, { type: kept.mimeType }) : undefined;
    },
  };
  return { keeper, bytes };
}

test("F1: a finished file's bytes are kept (the ones uploaded), and a relaunched tray has them again", async () => {
  const { keeper, bytes } = book();
  const drafts = new AttachmentDrafts(keeper);
  await drafts.load();
  // The app's preparation changed the file: its bytes are the ones kept.
  drafts.add(
    "a",
    new File(["raw!!!"], "photo.txt"),
    async (_signal, _progress, sending) => {
      sending(new File(["clean"], "photo.txt"));
      return part("h1");
    },
    "failed",
  );
  await settle();
  expect(await bytes.get("h1")?.text()).toBe("clean");

  // A relaunch: the part comes back from the app with its bytes, not an empty file.
  const next = new AttachmentDrafts(keeper);
  await next.load();
  expect(next.files("a")).toHaveLength(0);
  const relaunched = new AttachmentDrafts({
    ...keeper,
    load: async () => ({ attachments: { a: [part("h1")] }, legacy: {}, files: { a: { h1: Date.now() } } }),
  });
  await relaunched.load();
  const [item] = relaunched.files("a");
  expect(item?.part?.hash).toBe("h1");
  expect(item?.file.size).toBe(5);
  expect(await item?.file.text()).toBe("clean");
  // Removing it lets the app's bytes go too.
  relaunched.remove("a", item!.id);
  expect(bytes.has("h1")).toBe(false);
  expect(parseKeptAttachments({ attachments: {}, legacy: {}, files: { a: { h1: 3, bad: "x" } } }).files).toEqual({
    a: { h1: 3 },
  });
});

test("round 7 F2: a file whose bytes the app refuses is not kept either, so no relaunch restores it empty", async () => {
  const entries = new Map<string, HomeAttachment>();
  const keeper = {
    load: async (): Promise<KeptAttachments> => ({ attachments: {}, legacy: {} }),
    put: (_conversation: string, kept: HomeAttachment) => void entries.set(kept.hash, kept),
    remove: (_conversation: string, hash: string) => void entries.delete(hash),
    release: () => {},
    write: async () => false,
  };
  const drafts = new AttachmentDrafts(keeper);
  await drafts.load();
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  await settle();
  expect(entries.has("h1")).toBe(false);
  // It stays in this tray (it still sends now), and the page says it is not kept.
  expect(drafts.files("a").map((item) => item.part?.hash)).toEqual(["h1"]);
  expect(drafts.holdReason()).toBe("home.attachments");
});

test("F1: a restored file whose upload is older than the owner keeps it goes up again from its bytes", async () => {
  const { keeper, bytes } = book();
  bytes.set("h1", new Blob(["notes"]));
  const old = Date.now() - REFRESH_AFTER_MS - 1000;
  const drafts = new AttachmentDrafts({
    ...keeper,
    load: async () => ({
      attachments: { a: [part("h1"), part("h2")] },
      legacy: {},
      files: { a: { h1: old, h2: Date.now() } },
    }),
  });
  bytes.set("h2", new Blob(["fresh"]));
  await drafts.load();
  const uploaded: string[] = [];
  drafts.uploadLegacy(async (_conversation, file) => {
    uploaded.push(await file.text());
    return part("h1");
  }, "failed");
  await settle();
  expect(uploaded).toEqual(["notes"]);
});

/** A client whose first send of files is refused `unknown_attachment` (the owner collected the upload). */
function ownerClient(log: { sends: Record<string, unknown>[]; uploads: number }, refuse = 1) {
  const people = [{ id: "me", kind: "human", name: "Me", chief: false }];
  const dm = {
    id: "dm",
    owner: "local",
    title: "dm",
    kind: "direct",
    participants: people,
    lastSeq: 0,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  let refused = 0;
  return {
    call: async (op: string, params: Record<string, unknown>) => {
      if (op === HomeOps.send) {
        log.sends.push(params);
        if ((params.attachments as unknown[] | undefined)?.length && refused < refuse) {
          refused += 1;
          throw pageError("cmux.page.invalid_params", "unknown_attachment");
        }
        return { rev: 2 };
      }
      if (op === HomeOps.inbox) return { me: people[0], conversations: [dm], rev: 1 };
      if (op === HomeOps.page) return { conversation: dm, messages: [], hasOlder: false };
      if (op === HomeOps.attachmentSupport) return { local: true, cloud: true };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

test("F1: a send the owner refuses for a file it let go of uploads the kept bytes again and goes", async () => {
  const log = { sends: [] as Record<string, unknown>[], uploads: 0 };
  const store = new HomeChannelsStore(ownerClient(log) as never);
  await store.reloadInbox();
  await store.select("dm");
  const drafts = new AttachmentDrafts();
  const uploadedTexts: string[] = [];
  drafts.uploadLegacy(async (_conversation, file) => {
    uploadedTexts.push(await file.text());
    return { ...part("h1"), preview: undefined } as HomeAttachment;
  }, "failed");
  drafts.add("dm", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  const ready = drafts.files("dm").map((item) => item.part!);
  drafts.take("dm", ready);
  store.reupload = (conversation, parts, signal) => drafts.resend(conversation, parts, signal);
  expect(await store.send("", undefined, undefined, ready)).toBe(true);
  await settle();
  await settle();
  expect(uploadedTexts).toEqual(["notes"]);
  expect(log.sends).toHaveLength(2);
  expect(store.getSnapshot().pending.filter((entry) => entry.failed)).toHaveLength(0);
});

test("F1: without the bytes the refused send shows Not Delivered, as before", async () => {
  const log = { sends: [] as Record<string, unknown>[], uploads: 0 };
  const store = new HomeChannelsStore(ownerClient(log) as never);
  await store.reloadInbox();
  await store.select("dm");
  const drafts = new AttachmentDrafts();
  drafts.uploadLegacy(async () => part("h1"), "failed");
  store.reupload = (conversation, parts, signal) => drafts.resend(conversation, parts, signal);
  await store.send("", undefined, undefined, [part("h9")]);
  await settle();
  expect(log.sends).toHaveLength(1);
  expect(store.getSnapshot().pending.map((entry) => entry.failed)).toEqual([true]);
});

test("Cancel Upload: a send with files that is still going stops and leaves, one with short text cannot", async () => {
  let release: (() => void) | undefined;
  const people = [{ id: "me", kind: "human", name: "Me", chief: false }];
  const client = {
    call: async (op: string, _params: unknown, options?: { signal?: AbortSignal }) => {
      if (op === HomeOps.send)
        return new Promise((resolve, reject) => {
          release = () => resolve({});
          options?.signal?.addEventListener("abort", () => reject(pageError("cmux.op.cancelled", "cancelled")));
        });
      if (op === HomeOps.inbox)
        return {
          me: people[0],
          conversations: [{ id: "dm", owner: "local", title: "dm", kind: "direct", participants: people }],
          rev: 1,
        };
      if (op === HomeOps.page) return { messages: [], hasOlder: false };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  await store.reloadInbox();
  await store.select("dm");
  await store.send("hi");
  const [text] = store.getSnapshot().pending;
  expect(store.canCancel(text!.key)).toBe(false);
  release!();
  await settle();
  await store.send("", undefined, undefined, [part("h1")]);
  const files = store.getSnapshot().pending.find((entry) => entry.attachments);
  expect(store.canCancel(files!.key)).toBe(true);
  store.cancel(files!.key);
  await settle();
  expect(store.getSnapshot().pending.some((entry) => entry.key === files!.key)).toBe(false);
  expect(store.canCancel(files!.key)).toBe(false);
});

function dragEvent(type: string, files: File[]) {
  const event = new dom!.window.Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", {
    value: { types: ["Files"], files: Object.assign([...files], { item: (i: number) => files[i] }), dropEffect: "" },
  });
  return event;
}

test("a file dropped on the conversation list goes to the shown conversation, with its highlight; not on New Message", async () => {
  const container = installDom();
  const log = { sends: [] as Record<string, unknown>[], uploads: 0 };
  const store = new HomeChannelsStore(ownerClient(log) as never);
  await store.reloadInbox();
  await store.select("dm");
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessagesApp
        store={store}
        strings={strings}
        host={null}
        messages={noMessagesHost}
        nav={nav}
        widthStorage={null}
        detail={(props) => <MessagesDetail {...props} />}
      />,
    );
  });
  await settle();
  const column = container.querySelector(".hm-column")!;
  const over = dragEvent("dragover", []);
  await act(async () => void column.dispatchEvent(over));
  expect(over.defaultPrevented).toBe(true);
  expect(container.querySelector(".mt-drop-highlight")).not.toBeNull();
  await act(async () => void column.dispatchEvent(dragEvent("drop", [new File(["notes"], "notes.txt")])));
  await settle();
  expect(container.querySelector(".mt-drop-highlight")).toBeNull();
  expect(nav.attachments.files("dm").map((item) => item.file.name)).toEqual(["notes.txt"]);

  // New Message takes no drop.
  await act(async () => {
    nav.openCompose();
  });
  await settle();
  const composing = dragEvent("dragover", []);
  await act(async () => void column.dispatchEvent(composing));
  expect(composing.defaultPrevented).toBe(false);
});
