// Audit hq#1925 item 13 (2026-10-12): Chief showed unread (`unread` 6, the tile's dot) while its
// conversation was open on screen. The page moves the read cursor for a message that arrives only
// while the page is visible; replies that came while it was hidden (a background workspace, an
// occluded window, a sleeping display) stayed unread once it showed again, with the person reading
// them. Showing the page reads the open conversation through its newest message.
//
// The page talks to its host through `cmux.home.*`; a stand-in host records the reads it sends.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
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

test("replies that came while the page was hidden are read once it shows", async () => {
  const reads: number[] = [];
  let deliver: ((batch: Batch) => void) | undefined;
  const client = {
    async call(op: string, params: { seq?: number }) {
      switch (op) {
        case HomeOps.inbox:
          return { me, conversations: [conversation(1, 0)], rev: 1 };
        case HomeOps.page:
          return { conversation: conversation(1, 0), messages: [message(1, "me")] };
        case HomeOps.read:
          reads.push(params.seq ?? -1);
          return {};
        default:
          return {};
      }
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
  expect(store.getSnapshot().selected).toBe("chief-conv");

  // The window goes behind another; Chief answers.
  visibility = "hidden";
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
  deliver?.({ conversations: [conversation(3, 2)], messages: [message(2, "chief"), message(3, "chief")] });
  expect(reads).toEqual([]);

  // The person comes back to the open conversation and reads the replies.
  visibility = "visible";
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
  await Promise.resolve();
  expect(reads).toEqual([3]);
  stop();
});
