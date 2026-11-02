// #25570: a Chief chat's history must be complete after a relaunch. The Chief answers in threads,
// so the newest page of a busy Chief conversation can be all thread replies, which the timeline
// does not draw: the restored chat showed a short tail or "no messages" with no scroller to page
// back from. Opening it pages older history until the timeline has messages to show.
// And a reconnect after more than a page of messages arrived left a hole between the old window
// and the new page that no scroll ever filled.
//
// The page talks to its host through `cmux.home.*`; a stand-in host serves a seeded conversation.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => "visible" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => Object.assign(scope, saved));

const { HomeChannelsStore, PAGE } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { threadOf } = await import("../src/pages/home-channels/model");
type Conversation = import("../src/pages/home-channels/types").HomeConversation;
type Message = import("../src/pages/home-channels/types").HomeMessage;

const me = { id: "me", kind: "human" as const, name: "Me", chief: false };
const chief = { id: "chief", kind: "agent" as const, name: "Chief", chief: true };
const conversation = (lastSeq: number): Conversation => ({
  id: "chief-conv",
  owner: "local",
  title: "Chief",
  kind: "chief",
  participants: [me, chief],
  lastSeq,
  rev: lastSeq,
  updatedAt: lastSeq,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
});
const message = (seq: number, threadRoot?: string): Message => ({
  id: `m${seq}`,
  conversation: "chief-conv",
  seq,
  author: threadRoot ? "chief" : "me",
  createdAt: seq,
  retracted: false,
  parts: [{ type: "text", text: `message ${seq}`, mentions: [] }],
  reactions: [],
  ...(threadRoot ? { threadRoot } : {}),
});

/** A host whose conversation is `all` (ascending by seq). `during(op)` runs inside a read, before it
 * answers: an event the owner sends meanwhile, or another read. */
const host = (all: () => Message[], during: (op: string) => Promise<void> = async () => {}) => {
  let reconnect: (() => void) | undefined;
  let deliver: ((batch: unknown) => void) | undefined;
  const client = {
    async call(op: string, params: { tail?: number; beforeSeq?: number; limit?: number }) {
      const messages = all();
      const last = messages.at(-1)?.seq ?? 0;
      await during(op);
      switch (op) {
        case HomeOps.inbox:
          return { me, conversations: [conversation(last)], rev: last };
        case HomeOps.page:
          return { conversation: conversation(last), messages: messages.slice(-(params.tail ?? PAGE)) };
        case HomeOps.history: {
          const before = messages.filter((m) => m.seq < (params.beforeSeq ?? Infinity));
          return { messages: before.slice(-(params.limit ?? PAGE)) };
        }
        default:
          return {};
      }
    },
    async subscribe(stream: string, onEvent: (data: unknown) => void) {
      if (stream === HomeOps.events) deliver = onEvent;
      return () => {};
    },
    handle: (_op: string, fn: () => void) => {
      reconnect = fn;
      return () => {};
    },
  };
  return {
    client,
    reconnect: () => reconnect?.(),
    event: (messages: Message[]) => deliver?.({ conversations: [conversation(messages.at(-1)!.seq)], messages }),
  };
};

const topLevel = (messages: readonly Message[]) => messages.filter((m) => !threadOf(m));

test("a restored Chief chat whose newest page is all thread replies pages back to messages it can show", async () => {
  // 20 top-level messages, then 250 thread replies of the Chief under the last one.
  const all = [
    ...Array.from({ length: 20 }, (_, i) => message(i + 1)),
    ...Array.from({ length: 250 }, (_, i) => message(21 + i, "m20")),
  ];
  const store = new HomeChannelsStore(host(() => all).client as never);
  const stop = store.subscribe(() => {});
  await store.start();
  const snapshot = store.getSnapshot();
  expect(snapshot.selected).toBe("chief-conv");
  expect(topLevel(snapshot.messages).map((m) => m.seq)).toEqual(all.slice(0, 20).map((m) => m.seq));
  expect(snapshot.hasOlder).toBe(false);
  stop();
});

test("opening a long Chief chat does not read its whole history", async () => {
  // Plenty of top-level messages in the newest page: no older page is read.
  const all = Array.from({ length: 1000 }, (_, i) => message(i + 1));
  const reads: string[] = [];
  const { client } = host(() => all);
  const counting = { ...client, call: (op: string, params: never) => (reads.push(op), client.call(op, params)) };
  const store = new HomeChannelsStore(counting as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(reads.filter((op) => op === HomeOps.history)).toEqual([]);
  expect(store.getSnapshot().messages).toHaveLength(PAGE);
  expect(store.getSnapshot().hasOlder).toBe(true);
  stop();
});

test("a reload after more than a page arrived leaves no hole in the window", async () => {
  let all = Array.from({ length: 50 }, (_, i) => message(i + 1));
  const { client } = host(() => all);
  const store = new HomeChannelsStore(client as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(store.getSnapshot().messages.map((m) => m.seq)).toEqual(all.map((m) => m.seq));

  // Offline while 300 more came in; the inbox read after the reconnect reloads the open page.
  all = Array.from({ length: 350 }, (_, i) => message(i + 1));
  await store.reloadInbox();
  const seqs = store.getSnapshot().messages.map((m) => m.seq);
  // Contiguous: every seq from the first loaded one to the newest.
  expect(seqs).toEqual(Array.from({ length: seqs.length }, (_, i) => seqs[0]! + i));
  expect(seqs.at(-1)).toBe(350);
  expect(store.getSnapshot().hasOlder).toBe(true);

  // Scrolling up reaches the start, with nothing missing.
  for (let i = 0; i < 10 && store.getSnapshot().hasOlder; i += 1) await store.loadOlder();
  expect(store.getSnapshot().messages.map((m) => m.seq)).toEqual(all.map((m) => m.seq));
  stop();
});

const contiguous = (seqs: number[]) => seqs.every((seq, i) => i === 0 || seq === seqs[i - 1]! + 1);

test("a message that arrives while the reload reads leaves no hole either", async () => {
  let all = Array.from({ length: 50 }, (_, i) => message(i + 1));
  let onPage: (() => void) | undefined;
  const fake = host(
    () => all,
    async (op) => {
      if (op === HomeOps.page) onPage?.();
    },
  );
  const store = new HomeChannelsStore(fake.client as never);
  const stop = store.subscribe(() => {});
  await store.start();

  // 300 came in while offline; message 351 arrives as an event while the reload's page is read.
  all = Array.from({ length: 350 }, (_, i) => message(i + 1));
  onPage = () => {
    onPage = undefined;
    fake.event([message(351)]);
    all = [...all, message(351)];
  };
  await store.reloadInbox();
  const seqs = store.getSnapshot().messages.map((m) => m.seq);
  expect(contiguous(seqs)).toBe(true);
  expect(seqs.at(-1)).toBe(351);
  expect(store.getSnapshot().hasOlder).toBe(true);
  stop();
});

test("an older page read before a reload moved the window is not merged into it", async () => {
  let all = Array.from({ length: 250 }, (_, i) => message(i + 1));
  let onHistory: (() => Promise<void>) | undefined;
  const fake = host(
    () => all,
    async (op) => {
      if (op === HomeOps.history && onHistory) {
        const run = onHistory;
        onHistory = undefined;
        await run();
      }
    },
  );
  const store = new HomeChannelsStore(fake.client as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(store.getSnapshot().messages[0]?.seq).toBe(151);

  // Scrolling up reads 51..150; meanwhile a reconnect reload finds 300 more and moves the window.
  onHistory = async () => {
    all = Array.from({ length: 550 }, (_, i) => message(i + 1));
    await store.reloadInbox();
  };
  await store.loadOlder();
  const seqs = store.getSnapshot().messages.map((m) => m.seq);
  expect(contiguous(seqs)).toBe(true);
  expect(seqs.at(-1)).toBe(550);
  stop();
});
