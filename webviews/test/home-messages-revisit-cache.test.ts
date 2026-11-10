// Going back to a conversation draws what it showed at once while its page is read again, instead
// of a blank transcript for messages the page already had; the page's answer then replaces that
// copy as if it had never been there (a message deleted meanwhile goes). Only the newest page of
// the last few conversations stays in memory.
import { expect, test } from "bun:test";
import { HomeChannelsStore, PAGE, RECENT_PAGES, RecentPages } from "../src/pages/home-channels/store";
import { HomeOps, type HomeMessage } from "../src/pages/home-channels/types";

const people = [
  { id: "me", kind: "human", name: "Me" },
  { id: "you", kind: "human", name: "You" },
];

function chat(id: string, lastSeq: number) {
  return {
    id,
    owner: "local",
    title: id,
    kind: "direct",
    participants: people,
    lastSeq,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
}

function message(conversation: string, seq: number): HomeMessage {
  return {
    id: `${conversation}-m${seq}`,
    conversation,
    seq,
    author: seq % 2 ? "me" : "you",
    createdAt: seq,
    parts: [{ type: "text", text: `${conversation} ${seq}` }],
    reactions: [],
  } as unknown as HomeMessage;
}

/** A client whose page answers wait for the test while `hold` is set. */
function client(pages: Map<string, HomeMessage[]>) {
  let held: ((value: unknown) => void)[] = [];
  const state = { hold: false };
  return {
    state,
    release: () => {
      for (const answer of held) answer(undefined);
      held = [];
    },
    call: async (op: string, params: { conversation?: string }) => {
      if (op === HomeOps.inbox)
        return { me: people[0], conversations: [...pages.keys()].map((id) => chat(id, pages.get(id)!.length)), rev: 1 };
      if (op === HomeOps.page) {
        if (state.hold) await new Promise((resolve) => held.push(resolve));
        const id = params.conversation!;
        // Each answer is a new copy, as one over the bridge is.
        const messages = pages.get(id)!.map((m) => ({ ...m }));
        return { conversation: chat(id, messages.length), messages, hasOlder: false };
      }
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

test("a revisit draws the conversation's last page at once, then the page's answer replaces it", async () => {
  const pages = new Map([
    ["a", [message("a", 1), message("a", 2), message("a", 3)]],
    ["b", [message("b", 1)]],
  ]);
  const host = client(pages);
  const store = new HomeChannelsStore(host as never);
  await store.reloadInbox();
  await store.select("a");
  await store.select("b");
  expect(store.getSnapshot().messages.map((m) => m.id)).toEqual(["b-m1"]);

  // Back to a while its page is on the way: what it showed, not a blank transcript.
  host.state.hold = true;
  pages.set("a", [message("a", 1), message("a", 3), message("a", 4)]);
  const opening = store.select("a");
  expect(store.getSnapshot().selected).toBe("a");
  expect(store.getSnapshot().messages.map((m) => m.id)).toEqual(["a-m1", "a-m2", "a-m3"]);
  host.release();
  await opening;
  // The answer is the page: a-m2 (deleted meanwhile) goes, a-m4 comes.
  expect(store.getSnapshot().messages.map((m) => m.id)).toEqual(["a-m1", "a-m3", "a-m4"]);
});

test("a conversation never shown, or one shown with nothing, opens blank until its page answers", async () => {
  const pages = new Map([
    ["a", [message("a", 1)]],
    ["b", [message("b", 1)]],
    ["c", [] as HomeMessage[]],
  ]);
  const host = client(pages);
  const store = new HomeChannelsStore(host as never);
  await store.reloadInbox();
  await store.select("a");
  host.state.hold = true;
  const opening = store.select("b");
  expect(store.getSnapshot().messages).toEqual([]);
  host.release();
  await opening;
  host.state.hold = false;
  await store.select("c");
  await store.select("a");
  host.state.hold = true;
  const back = store.select("c");
  expect(store.getSnapshot().messages).toEqual([]);
  host.release();
  await back;
});

test("only the newest page of the last few conversations is kept", () => {
  const recent = new RecentPages(RECENT_PAGES, PAGE);
  const long = Array.from({ length: PAGE + 50 }, (_, index) => message("x", index + 1));
  recent.keep("x", long);
  const seeded = recent.seed("x");
  expect(seeded.length).toBe(PAGE);
  expect(seeded[0]!.seq).toBe(51);
  expect(recent.seeded(seeded[0]!)).toBe(true);
  recent.release();
  expect(recent.seeded(seeded[0]!)).toBe(false);

  for (let index = 0; index < RECENT_PAGES; index += 1) recent.keep(`c${index}`, [message(`c${index}`, 1)]);
  // x was left first: it went when the ninth came.
  expect(recent.seed("x")).toEqual([]);
  expect(recent.seed("c0").length).toBe(1);
  // Another conversation's messages are not kept under this one.
  recent.keep("y", [message("z", 1)]);
  expect(recent.seed("y")).toEqual([]);
  recent.forget("c0");
  expect(recent.seed("c0")).toEqual([]);
});

test("a link's last answer is kept for its next hover card, the most recent links only", async () => {
  const { RecentPreviews } = await import("../src/pages/home-messages/cards/links/HomeLinkChip");
  const recent = new RecentPreviews(2);
  const preview = (title: string) => ({ kind: "web", title }) as never;
  recent.keep("web\na", preview("A"));
  recent.keep("web\nb", preview("B"));
  recent.keep("web\na", preview("A2"));
  recent.keep("web\nc", preview("C"));
  // b was the least recent: it went.
  expect(recent.get("web\nb")).toBeUndefined();
  expect(recent.get("web\na")).toEqual(preview("A2"));
  expect(recent.get("web\nc")).toEqual(preview("C"));
});
