import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import {
  STASH_CHATS,
  STASH_LIMIT,
  entryKey,
  moveStash,
  resetStashForTests,
  stashDraft,
  stashedChips,
  stashPreview,
  storedStacks,
  takeStashed,
  type ChipStore,
} from "./draftStash";

// The page's localStorage: an in-memory one, as a test has none. `full` makes every write throw.
const stored = new Map<string, string>();
let full = false;
const memoryStorage = {
  get length() {
    return stored.size;
  },
  key: (index: number) => [...stored.keys()][index] ?? null,
  getItem: (key: string) => stored.get(key) ?? null,
  setItem: (key: string, value: string) => {
    if (full) throw new Error("QuotaExceededError");
    stored.set(key, value);
  },
  removeItem: (key: string) => void stored.delete(key),
};
// Writable and given back after, as other files in this run set their own.
const pageStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
Object.defineProperty(globalThis, "localStorage", { configurable: true, writable: true, value: memoryStorage });
afterAll(() => {
  if (pageStorage) Object.defineProperty(globalThis, "localStorage", pageStorage);
  else delete (globalThis as { localStorage?: Storage }).localStorage;
});

// The chip store: an in-memory one, as a test has no IndexedDB.
const chips = new Map<string, ComposerAttachment[]>();
const memoryChips: ChipStore = {
  put: async (id, list) => void chips.set(id, [...list]),
  get: async (id) => chips.get(id),
  drop: async (id) => void chips.delete(id),
  ids: async () => [...chips.keys()],
};

beforeEach(() => {
  stored.clear();
  chips.clear();
  full = false;
  resetStashForTests(memoryChips);
});
afterEach(() => resetStashForTests());

const image = (id: string, bytes = 10): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: bytes,
  data: "A".repeat(bytes),
});
const texts = (chat: string) => (storedStacks(memoryStorage).get(chat) ?? []).map((entry) => entry.text);

describe("draft stash", () => {
  test("stash then take brings the newest back first, and an empty draft is not stashed", () => {
    expect(stashDraft("chat", "  ", [])).toBe(false);
    expect(stashDraft("chat", "first", [])).toBe(true);
    expect(stashDraft("chat", "second", [image("a")])).toBe(true);
    const newest = takeStashed("chat");
    expect(newest?.text).toBe("second");
    expect(newest?.attachments.map((chip) => chip.id)).toEqual(["a"]);
    expect(takeStashed("chat")?.text).toBe("first");
    expect(takeStashed("chat")).toBeUndefined();
  });

  test("a pick by id takes that draft, and the stacks are per chat", () => {
    void stashDraft("one", "a", []);
    void stashDraft("one", "b", []);
    void stashDraft("two", "c", []);
    const olderId = storedStacks(memoryStorage)
      .get("one")
      ?.find((entry) => entry.text === "a")?.id;
    expect(takeStashed("one", olderId)?.text).toBe("a");
    expect(takeStashed("one", "no-such-id")).toBeUndefined();
    expect(takeStashed("two")?.text).toBe("c");
    expect(takeStashed("one")?.text).toBe("b");
  });

  test("the stack holds at most STASH_LIMIT drafts, the oldest let go", () => {
    for (let index = 0; index < STASH_LIMIT + 2; index += 1) void stashDraft("chat", `draft ${index}`, []);
    const taken: string[] = [];
    for (let entry = takeStashed("chat"); entry; entry = takeStashed("chat")) taken.push(entry.text);
    expect(taken.length).toBe(STASH_LIMIT);
    expect(taken[0]).toBe(`draft ${STASH_LIMIT + 1}`);
    expect(taken.at(-1)).toBe("draft 2");
  });

  test("at most STASH_CHATS chats keep a stack, the one used longest ago let go", () => {
    for (let index = 0; index <= STASH_CHATS; index += 1) void stashDraft(`chat ${index}`, "draft", []);
    expect(storedStacks(memoryStorage).size).toBe(STASH_CHATS);
    expect(storedStacks(memoryStorage).has(`chat ${STASH_CHATS}`)).toBe(true);
  });

  test("a reload keeps the stacks, a large entry's chips with their contents", async () => {
    void stashDraft("chat", "small", [image("s")]);
    expect(await stashDraft("chat", "large", [image("l", 400 * 1024)])).toBe(true);
    // localStorage holds the large chip without its contents; the chip store has them.
    const list = storedStacks(memoryStorage).get("chat") ?? [];
    expect(list.map((entry) => entry.text)).toEqual(["large", "small"]);
    expect(list[0]!.attachments.map((chip) => [chip.id, chip.data])).toEqual([["l", undefined]]);
    expect(list[0]!.held).toEqual(["l"]);
    expect(list[1]!.attachments.map((chip) => chip.id)).toEqual(["s"]);
    // A reload: a new page reads the stack back, and the large draft comes back whole.
    resetStashForTests(memoryChips);
    const large = takeStashed("chat")!;
    expect(large.text).toBe("large");
    const back = await stashedChips(large);
    expect(back.map((chip) => chip.data?.length)).toEqual([400 * 1024]);
    expect(chips.size).toBe(0);
    expect((await stashedChips(takeStashed("chat")!)).map((chip) => chip.id)).toEqual(["s"]);
  });

  test("a draft that cannot be kept is not stashed", async () => {
    full = true;
    expect(stashDraft("chat", "small", [])).toBe(false);
    expect(await stashDraft("chat", "large", [image("l", 400 * 1024)])).toBe(false);
    expect(chips.size).toBe(0);
    full = false;
    resetStashForTests({ ...memoryChips, put: async () => Promise.reject(new Error("no IndexedDB")) });
    expect(await stashDraft("chat", "large", [image("l", 400 * 1024)])).toBe(false);
    expect(takeStashed("chat")).toBeUndefined();
  });

  test("a held entry let go drops its chips", async () => {
    await stashDraft("chat", "large", [image("l", 400 * 1024)]);
    for (let index = 0; index < STASH_LIMIT; index += 1) void stashDraft("chat", `draft ${index}`, []);
    expect(chips.size).toBe(0);
  });

  test("two panes stashing in the same chat keep both drafts", () => {
    void stashDraft("chat", "this pane's", []);
    // Another pane, sharing localStorage, stashes in the same chat after this page loaded.
    const other = { id: "stash-other", text: "the other pane's", attachments: [], at: Date.now() + 1 };
    stored.set(entryKey("chat", other.id), JSON.stringify(other));
    void stashDraft("chat", "this pane's second", []);
    expect(new Set(texts("chat"))).toEqual(new Set(["this pane's second", "the other pane's", "this pane's"]));
  });

  test("a new chat's stack follows it to its session", () => {
    void stashDraft("new-a", "before the session", []);
    void stashDraft("new-b", "another new chat's", []);
    moveStash("new-a", "session-1");
    expect(takeStashed("new-a")).toBeUndefined();
    expect(takeStashed("session-1")?.text).toBe("before the session");
    expect(texts("new-b")).toEqual(["another new chat's"]);
  });

  test("stored text that is not an entry reads as none", () => {
    stored.set(entryKey("chat", "x"), "not json");
    stored.set(entryKey("chat", "y"), '{"id": 1}');
    stored.set(entryKey("chat", "z"), JSON.stringify({ id: "other", text: "t", at: 0 }));
    expect(storedStacks(memoryStorage).size).toBe(0);
  });

  test("the preview is one line", () => {
    expect(stashPreview({ id: "x", text: "line one\n\n  line   two", attachments: [], at: 0 })).toBe(
      "line one line two",
    );
  });
});
