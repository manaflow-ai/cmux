// Viewing presence (chat multiplayer, hq#4389 section 5): the owner's `conversation-presence`
// frames map into the open conversation's `viewing`; nothing of it is stored.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => Object.assign(scope, saved));

const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
type Batch = import("../src/pages/home-channels/types").HomeEventBatch;
type Conversation = import("../src/pages/home-channels/types").HomeConversation;
type Message = import("../src/pages/home-channels/types").HomeMessage;

const me = { id: "me", kind: "human" as const, name: "Me", chief: false };
const chief = { id: "chief", kind: "agent" as const, name: "Chief", chief: true };
const conversation = (lastSeq: number, unread: number): Conversation => ({
  id: "chief-conv",
  owner: "local",
  title: "Chief",
  kind: "chief",
  participants: [me, chief],
  lastSeq,
  rev: lastSeq,
  updatedAt: lastSeq,
  unread,
  mentions: 0,
  muted: false,
  pinned: false,
});
const message = (seq: number, author: string): Message => ({
  id: `m${seq}`,
  conversation: "chief-conv",
  seq,
  author,
  createdAt: seq,
  retracted: false,
  parts: [{ type: "text", text: `${author} ${seq}`, mentions: [] }],
  reactions: [],
});

test("viewing presence follows the owner's frames, per conversation, and ends on a reconnect", async () => {
  let deliver: ((batch: Batch) => void) | undefined;
  const client = {
    async call(op: string) {
      if (op === HomeOps.inbox) return { me, conversations: [conversation(1, 0)], rev: 1 };
      if (op === HomeOps.page) return { conversation: conversation(1, 0), messages: [message(1, "me")] };
      return {};
    },
    async subscribe(stream: string, onEvent: (data: unknown) => void) {
      if (stream === HomeOps.events) deliver = onEvent as (batch: Batch) => void;
      return () => {};
    },
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(store.getSnapshot().viewing).toEqual([]);
  const ana = { participant: "tailnet:ana@example.com", viewing: true };
  deliver?.({
    presence: [{ conversation: "chief-conv", participants: [ana, { participant: "sam", viewing: false }] }],
  });
  expect(store.getSnapshot().viewing).toEqual(["tailnet:ana@example.com"]);
  // Another conversation's presence does not show in the open one.
  deliver?.({ presence: [{ conversation: "other", participants: [{ participant: "sam", viewing: true }] }] });
  expect(store.getSnapshot().viewing).toEqual(["tailnet:ana@example.com"]);
  // An inbox refetch keeps the set; a lost connection ends it.
  deliver?.({ inboxStale: true });
  expect(store.getSnapshot().viewing).toEqual(["tailnet:ana@example.com"]);
  // A stream overflow may have lost the frame that took someone out: the set is unknown.
  deliver?.({ inboxStale: true, presenceLost: true });
  expect(store.getSnapshot().viewing).toEqual([]);
  deliver?.({ presence: [{ conversation: "chief-conv", participants: [ana] }] });
  expect(store.getSnapshot().viewing).toEqual(["tailnet:ana@example.com"]);
  deliver?.({ connection: "connecting" });
  expect(store.getSnapshot().viewing).toEqual([]);
  stop();
});
