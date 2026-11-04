// The guest's own messages (agent-session/guest/guestPrompts.ts): a client id made once and kept
// across a reload, the room's states folded in, what a reconnect resends and asks about, and what
// is kept.
import { expect, test } from "bun:test";
import { GuestPrompts, PROMPT_MAX_BYTES, promptBytes } from "../src/agent-session/guest/guestPrompts";
import { memoryStorage } from "../src/agent-session/guest/fixtures/liveChat";

let counter = 0;
const random = (bytes: Uint8Array) => bytes.fill(++counter);

test("a message keeps its client id across a reload, and the room's states fold in", () => {
  const tab = memoryStorage();
  const prompts = new GuestPrompts("share", tab, random, () => 1);
  const first = prompts.add("Run it on Linux too");
  expect(first.clientId).toMatch(/^[0-9a-f]{32}$/);
  expect(prompts.unsent().map((each) => each.clientId)).toEqual([first.clientId]);
  const reloaded = new GuestPrompts("share", tab, random);
  expect(reloaded.list()).toEqual([first]);
  reloaded.update({ client_id: first.clientId, prompt_id: "g-1", state: "held" });
  expect(reloaded.unsent()).toEqual([]);
  expect(reloaded.held()).toEqual([first.clientId]);
  reloaded.snapshot([{ client_id: first.clientId, state: "declined" }]);
  expect(reloaded.held()).toEqual([]);
  expect(reloaded.list()[0]!.state).toBe("declined");
  // A state for a message this tab never wrote, or an unknown state, changes nothing.
  reloaded.update({ client_id: "other", state: "approved" });
  reloaded.update({ client_id: first.clientId, state: "weird" as never });
  expect(reloaded.list().map((each) => each.state)).toEqual(["declined"]);
});

test("a refusal keeps its reason; listeners hear each change", () => {
  const prompts = new GuestPrompts("share", memoryStorage(), random);
  let heard = 0;
  prompts.subscribe(() => (heard += 1));
  const sent = prompts.add("x");
  prompts.update({ client_id: sent.clientId, state: "refused", reason: "share.too_many_held" });
  expect(prompts.list()[0]).toMatchObject({ state: "refused", reason: "share.too_many_held" });
  expect(heard).toBe(2);
});

test("every waiting message is kept; only the newest 16 decided ones are", () => {
  const prompts = new GuestPrompts("share", memoryStorage(), random);
  const waiting = prompts.add("waiting");
  for (let index = 0; index < 20; index += 1) {
    const each = prompts.add(`decided ${index}`);
    prompts.update({ client_id: each.clientId, state: "approved" });
  }
  const list = prompts.list();
  expect(list[0]!.clientId).toBe(waiting.clientId);
  expect(list.length).toBe(17);
  expect(list.at(-1)!.text).toBe("decided 19");
});

test("the size bound counts UTF-8 bytes", () => {
  expect(promptBytes("é")).toBe(2);
  expect(promptBytes("a".repeat(PROMPT_MAX_BYTES))).toBe(PROMPT_MAX_BYTES);
});

test("retry keeps the refused send's text and original identity across reload", () => {
  const storage = memoryStorage();
  const prompts = new GuestPrompts("chief", storage, random);
  const first = prompts.add("Build a hello page");
  prompts.update({ client_id: first.clientId, state: "refused", reason: "offline" });
  const reloaded = new GuestPrompts("chief", storage, random);
  reloaded.retry(first.clientId);
  expect(reloaded.unsent()).toEqual([{ ...first, reason: undefined }]);
  reloaded.update({ client_id: first.clientId, state: "approved" });
  reloaded.retry(first.clientId);
  expect(reloaded.unsent()).toEqual([]);
});

test("each guest of a share keeps its own outbox; an old by-share outbox moves to its guest once", async () => {
  const { adoptUnscopedPrompts, forgetPrompts, guestScope } = await import("../src/agent-session/guest/guestPrompts");
  const tab = memoryStorage();
  const link = new GuestPrompts(guestScope("share", "g-link"), tab, random);
  link.add("Link guest's");
  expect(new GuestPrompts(guestScope("share", "g-invitee"), tab, random).list()).toEqual([]);
  expect(new GuestPrompts(guestScope("share", "g-link"), tab, random).list().map((each) => each.text)).toEqual([
    "Link guest's",
  ]);
  // A tab from before: its messages were kept by share alone, and the guest it joined as reloads.
  const old = memoryStorage();
  new GuestPrompts("share", old, random).add("Kept by share");
  adoptUnscopedPrompts(old, "share", "g1");
  expect(old.getItem("cmux.guest.share.prompts")).toBeNull();
  expect(new GuestPrompts(guestScope("share", "g1"), old, random).list().map((each) => each.text)).toEqual([
    "Kept by share",
  ]);
  adoptUnscopedPrompts(old, "share", "g1");
  expect(new GuestPrompts(guestScope("share", "g1"), old, random).list().length).toBe(1);
  forgetPrompts(old, "share", "g1");
  expect(new GuestPrompts(guestScope("share", "g1"), old, random).list()).toEqual([]);
});

test("a storage too full to move the old outbox keeps it, and a later move merges both", async () => {
  const { adoptUnscopedPrompts, guestScope } = await import("../src/agent-session/guest/guestPrompts");
  const tab = memoryStorage();
  new GuestPrompts("share", tab, random, () => 1).add("Written before the move");
  const setItem = tab.setItem;
  tab.setItem = () => {
    throw new Error("QuotaExceededError");
  };
  adoptUnscopedPrompts(tab, "share", "g1");
  tab.setItem = setItem;
  expect(tab.getItem("cmux.guest.share.prompts")).not.toBeNull();
  // The guest writes to its own outbox meanwhile; the next reload keeps both.
  new GuestPrompts(guestScope("share", "g1"), tab, random, () => 2).add("Written after");
  adoptUnscopedPrompts(tab, "share", "g1");
  expect(tab.getItem("cmux.guest.share.prompts")).toBeNull();
  expect(new GuestPrompts(guestScope("share", "g1"), tab, random).list().map((each) => each.text)).toEqual([
    "Written before the move",
    "Written after",
  ]);
});
