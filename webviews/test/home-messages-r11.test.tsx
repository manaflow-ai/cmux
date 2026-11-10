// Review round 11 of cmux#37736: nothing leaves one owner before the next said it saved it. A tray
// file holds a web update's reload until the app answered its bytes (F2) and lets the native
// composer's copy go only then; a draft, a send and a removal hold it until answered; a send the
// app refused keeps its files' tray entries. A thread keeps the conversation's controls (F3: the
// Chief's Stop, Escape, Continue and toast, the header), and the composer reports my typing (F4).
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const window = dom.window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const values = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
    Element: window.Element,
    Node: window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  } as Record<string, unknown>;
  for (const key of Object.keys(values)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, values);
  return window.document.getElementById("root")!;
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

const { AttachmentDrafts } = await import("../src/pages/home-messages/transcript/attachmentDrafts");
const { MessagesNav, DRAFT_SAVE_DELAY_MS } = await import("../src/pages/home-messages/nav");
const { KeptPendingCarry } = await import("../src/pages/home-messages/outbox");
const { OutgoingTyping, COMPOSING_OP, TYPING_REPEAT_MS } =
  await import("../src/pages/home-messages/transcript/outgoingTyping");
const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { noMessagesHost } = await import("../src/pages/home-messages/host");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { useSyncExternalStore } = await import("react");
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type KeptAttachments = import("../src/pages/home-messages/transcript/attachmentDrafts").KeptAttachments;
type PendingSend = import("../src/pages/home-channels/store").PendingSend;
type HomeSnapshot = import("../src/pages/home-channels/store").HomeSnapshot;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

function part(hash: string, byteCount = 5): HomeAttachment {
  return { type: "attachment", hash, name: `${hash}.txt`, mimeType: "text/plain", byteCount };
}

/** A promise the test answers. */
function later<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { promise, resolve };
}

test("round 11 F2: a finished file holds the reload until the app answered its bytes", async () => {
  const writes: { hash: string; answer: ReturnType<typeof later<boolean>> }[] = [];
  const drafts = new AttachmentDrafts({
    load: async (): Promise<KeptAttachments> => ({ attachments: {}, legacy: {} }),
    put: async () => true,
    remove: async () => true,
    release: async () => true,
    write: (hash) => {
      const answer = later<boolean>();
      writes.push({ hash, answer });
      return answer.promise;
    },
  });
  await drafts.load();
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  // The upload returned its part; the bytes are still on their way to the app.
  expect(drafts.files("a")[0]?.part?.hash).toBe("h1");
  expect(writes.map((write) => write.hash)).toEqual(["h1"]);
  expect(drafts.holdReason()).toBe("home.attachments");
  await act(async () => writes[0]!.answer.resolve(true));
  await settle();
  expect(drafts.holdReason()).toBeNull();
});

test("round 11: an unanswered entry put holds the reload too, and a refused one keeps holding", async () => {
  const put = later<unknown>();
  const drafts = new AttachmentDrafts({
    load: async (): Promise<KeptAttachments> => ({ attachments: {}, legacy: {} }),
    put: () => put.promise,
    remove: () => {},
    release: () => {},
  });
  await drafts.load();
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  expect(drafts.holdReason()).toBe("home.attachments");
  await act(async () => put.resolve(false));
  await settle();
  expect(drafts.holdReason()).toBe("home.attachments");
});

test("round 11: the native composer's file is let go of only once the page's copy is the app's", async () => {
  const released: string[][] = [];
  const write = later<boolean>();
  const drafts = new AttachmentDrafts({
    load: async (): Promise<KeptAttachments> => ({
      attachments: {},
      legacy: { a: [{ hash: "n1", name: "old.txt", mimeType: "text/plain", data: btoa("notes") }] },
    }),
    put: async () => true,
    remove: () => {},
    release: (_conversation, migrated) => void released.push([...migrated]),
    write: () => write.promise,
  });
  await drafts.load();
  drafts.uploadLegacy(async () => part("h1"), "failed");
  await settle();
  expect(drafts.files("a")[0]?.part?.hash).toBe("h1");
  expect(released).toEqual([]);
  await act(async () => write.resolve(true));
  await settle();
  expect(released).toEqual([["n1"]]);
});

test("round 11: a typed draft holds the reload until the app answered its save; a refused one keeps holding", async () => {
  const saves: ReturnType<typeof later<boolean>>[] = [];
  jest.useFakeTimers();
  const nav = new MessagesNav({
    load: async () => ({}),
    save: () => {
      const answer = later<boolean>();
      saves.push(answer);
      return answer.promise;
    },
  });
  nav.keepDraft("a", "half a thought");
  expect(nav.holdReason()).toBe("home.draft");
  jest.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
  jest.useRealTimers();
  expect(saves).toHaveLength(1);
  expect(nav.holdReason()).toBe("home.draft");
  saves[0]!.resolve(true);
  await settle();
  expect(nav.holdReason()).toBeNull();
  nav.keepDraft("a", "x".repeat(10));
  nav.flushDrafts();
  saves[1]!.resolve(false);
  await settle();
  expect(nav.holdReason()).toBe("home.draft");
});

test("round 11: a hidden New Message with people holds the reload (the app keeps none)", () => {
  const nav = new MessagesNav();
  nav.openCompose();
  nav.setComposeDraft({ tokens: [{ kind: "contact", id: "ada", label: "Ada" }], query: "" } as never);
  nav.leaveCompose();
  expect(nav.getSnapshot().compose?.shown).toBe(false);
  expect(nav.holdReason()).toBe("home.newMessage");
  nav.closeCompose();
  expect(nav.holdReason()).toBeNull();
});

function sendRow(key: string, attachments?: HomeAttachment[]): PendingSend {
  return {
    key,
    conversation: "a",
    text: "hi",
    createdAt: 1,
    ...(attachments ? { attachments } : {}),
  } as PendingSend;
}

test("round 11: a send holds the reload until the app answered its put; a refused send keeps its files kept", async () => {
  const puts: ReturnType<typeof later<boolean>>[] = [];
  const handed: string[][] = [];
  const carry = new KeptPendingCarry(
    {
      load: async () => [],
      put: () => {
        const answer = later<boolean>();
        puts.push(answer);
        return answer.promise;
      },
      remove: async () => true,
    },
    (hashes) => handed.push([...hashes]),
  );
  await carry.load();
  carry.entries = [sendRow("k1")];
  expect(carry.holdReason()).toBe("home.sending");
  puts[0]!.resolve(true);
  await settle();
  expect(carry.holdReason()).toBeNull();

  // Refused (past the app's cap): it lives only here, and its files stay kept by their tray.
  carry.entries = [sendRow("k1"), sendRow("k2", [part("h2")])];
  puts[1]!.resolve(false);
  await settle();
  expect(carry.holdReason()).toBe("home.send-unkept");
  expect(handed).toEqual([]);
  // It leaves (delivered or discarded): only now do its files go.
  carry.entries = [sendRow("k1")];
  await settle();
  expect(handed).toEqual([["h2"]]);
  expect(carry.holdReason()).toBeNull();
});

test("round 11 F4: typing tells the app once, then at most once a second, and stops on empty", () => {
  const calls: unknown[] = [];
  let now = 0;
  const host = { call: async (op: string, params: unknown) => void calls.push([op, params]) };
  const typing = new OutgoingTyping(host as never, "dm", () => now);
  typing.changed("h");
  typing.changed("he");
  now += TYPING_REPEAT_MS;
  typing.changed("hel");
  typing.changed("   ");
  typing.stop();
  expect(calls).toEqual([
    [COMPOSING_OP, { conversation: "dm", typing: true }],
    [COMPOSING_OP, { conversation: "dm", typing: true }],
    [COMPOSING_OP, { conversation: "dm", typing: false }],
  ]);
});

/** A Chief chat with one root message and one reply in its thread. */
function chiefClient(calls: [string, unknown][]) {
  const people = [
    { id: "me", kind: "human", name: "Me", chief: false },
    { id: "chief", kind: "agent", name: "Chief", chief: true },
  ];
  const chat = {
    id: "c1",
    owner: "local",
    title: "Chief",
    kind: "chief",
    participants: people,
    lastSeq: 2,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const at = Date.now() - 60_000;
  const first = {
    id: "m1",
    conversation: "c1",
    seq: 1,
    author: "me",
    createdAt: at,
    parts: [{ type: "text", text: "root text" }],
    reactions: [],
  };
  const reply = {
    ...first,
    id: "m2",
    seq: 2,
    author: "chief",
    parts: [{ type: "text", text: "a reply" }],
    threadRoot: "m1",
  };
  return {
    call: async (op: string, params: unknown) => {
      calls.push([op, params]);
      if (op === HomeOps.inbox) return { me: people[0], conversations: [chat], rev: 1 };
      if (op === HomeOps.page) return { conversation: chat, messages: [first, reply], hasOlder: false };
      if (op === HomeOps.thread)
        return {
          root: first,
          replies: [reply],
          hasMore: false,
          thread: { root: "m1", replyCount: 1, authors: ["chief"] },
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
  host,
  working,
}: {
  store: InstanceType<typeof HomeChannelsStore>;
  nav: InstanceType<typeof MessagesNav>;
  host: unknown;
  working: boolean;
}) {
  const live = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const snapshot: HomeSnapshot = working ? { ...live, activity: new Map([["c1", new Set(["chief"])]]) } : live;
  const open = snapshot.selected ? snapshot.conversations.get(snapshot.selected) : undefined;
  return (
    <MessagesDetail
      store={store}
      snapshot={snapshot}
      conversation={open}
      me={snapshot.me}
      strings={strings}
      host={host as never}
      messages={noMessagesHost}
      chrome={{ windowControls: null }}
      nav={nav}
    />
  );
}

async function mountChief(calls: [string, unknown][]) {
  const container = installDom();
  const client = chiefClient(calls);
  const store = new HomeChannelsStore(client as never);
  await store.reloadInbox();
  await store.select("c1");
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(<Detail store={store} nav={nav} host={client} working />);
  });
  await settle();
  return { container, store };
}

const STOP_TITLE = "Stop the Chief (Option-click: Stop All Agents)";

test("round 11 F3: a thread opened while the Chief works keeps Stop, Escape and the header", async () => {
  const calls: [string, unknown][] = [];
  const { container, store } = await mountChief(calls);
  expect(container.querySelector(`[title="${STOP_TITLE}"]`)).not.toBeNull();
  await act(async () => void store.openThread("m1"));
  await settle();
  expect(store.getSnapshot().thread).toBe("m1");
  expect(container.querySelector(".hm-thread-bar")).not.toBeNull();
  const stop = container.querySelector<HTMLElement>(`[title="${STOP_TITLE}"]`);
  expect(stop).not.toBeNull();
  await act(async () => stop!.click());
  await settle();
  expect(calls.some(([op]) => op === "cmux.home.messages.chief.stop")).toBe(true);
});

test("round 11 F4: typing in the conversation and in its thread reports my typing; a send and leaving stop it", async () => {
  const calls: [string, unknown][] = [];
  const { container, store } = await mountChief(calls);
  const composing = () => calls.filter(([op]) => op === COMPOSING_OP).map(([, params]) => params);
  const type = async (text: string) => {
    const field = container.querySelector<MarkdownFieldElement>(".mt-field > div")!;
    await act(async () => {
      field.acpmuxMarkdownField!.focus();
      field.acpmuxMarkdownField!.type(text);
    });
    await settle();
  };
  await type("hello");
  expect(composing()).toEqual([{ conversation: "c1", typing: true }]);
  // The thread's message box is the conversation's: it reports too, and leaving ends it.
  await act(async () => void store.openThread("m1"));
  await settle();
  await type("");
  expect(composing().at(-1)).toEqual({ conversation: "c1", typing: false });
  await type("in the thread");
  expect(composing().at(-1)).toEqual({ conversation: "c1", typing: true });
  await act(async () => root!.unmount());
  root = undefined;
  expect(composing().at(-1)).toEqual({ conversation: "c1", typing: false });
});
