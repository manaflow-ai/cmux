import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import {
  STASH_LIMIT,
  STORAGE_KEY,
  moveStash,
  parseStacks,
  resetStashForTests,
  stashDraft,
  stashedChips,
  stashPreview,
  takeStashed,
  type ChipStore,
} from "./draftStash";

// The page's localStorage: an in-memory one, as a test has none.
const stored = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", {
  configurable: true,
  value: {
    getItem: (key: string) => stored.get(key) ?? null,
    setItem: (key: string, value: string) => void stored.set(key, value),
    removeItem: (key: string) => void stored.delete(key),
  },
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
    const list = parseStacks(stored.get(STORAGE_KEY)).get("one") ?? [];
    const olderId = list.find((entry) => entry.text === "a")?.id;
    expect(takeStashed("one", olderId)?.text).toBe("a");
    expect(takeStashed("one", "no-such-id")).toBeUndefined();
    expect(takeStashed("two")?.text).toBe("c");
    expect(takeStashed("one")?.text).toBe("b");
  });

  test("the stack holds at most STASH_LIMIT drafts, the oldest let go", () => {
    for (let index = 0; index < STASH_LIMIT + 2; index += 1) void stashDraft("chat", `draft ${index}`, []);
    const texts: string[] = [];
    for (let entry = takeStashed("chat"); entry; entry = takeStashed("chat")) texts.push(entry.text);
    expect(texts.length).toBe(STASH_LIMIT);
    expect(texts[0]).toBe(`draft ${STASH_LIMIT + 1}`);
    expect(texts.at(-1)).toBe("draft 2");
  });

  test("a reload keeps the stacks, a large entry's chips with their contents", async () => {
    void stashDraft("chat", "small", [image("s")]);
    expect(await stashDraft("chat", "large", [image("l", 400 * 1024)])).toBe(true);
    // localStorage holds the large chip without its contents; the chip store has them.
    const list = parseStacks(stored.get(STORAGE_KEY)).get("chat") ?? [];
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

  test("a large draft whose chips cannot be kept is not stashed", async () => {
    resetStashForTests({ ...memoryChips, put: async () => Promise.reject(new Error("no IndexedDB")) });
    expect(await stashDraft("chat", "large", [image("l", 400 * 1024)])).toBe(false);
    expect(takeStashed("chat")).toBeUndefined();
  });

  test("a held entry let go drops its chips", async () => {
    await stashDraft("chat", "large", [image("l", 400 * 1024)]);
    for (let index = 0; index < STASH_LIMIT; index += 1) void stashDraft("chat", `draft ${index}`, []);
    expect(chips.size).toBe(0);
  });

  test("another pane's stash is never written over", () => {
    void stashDraft("chat", "this pane's", []);
    // Another pane, sharing localStorage, stashes in the same chat after this page loaded.
    const other = parseStacks(stored.get(STORAGE_KEY));
    other.set("chat", [{ id: "other", text: "the other pane's", attachments: [], at: 1 }, ...other.get("chat")!]);
    stored.set(STORAGE_KEY, JSON.stringify(Object.fromEntries(other)));
    void stashDraft("chat", "this pane's second", []);
    const texts = (parseStacks(stored.get(STORAGE_KEY)).get("chat") ?? []).map((entry) => entry.text);
    expect(texts).toEqual(["this pane's second", "the other pane's", "this pane's"]);
  });

  test("a new chat's stack follows it to its session", () => {
    void stashDraft("new", "before the session", []);
    moveStash("new", "session-1");
    expect(takeStashed("new")).toBeUndefined();
    expect(takeStashed("session-1")?.text).toBe("before the session");
  });

  test("stored text that is not a stack reads as none", () => {
    expect(parseStacks("not json").size).toBe(0);
    expect(parseStacks('{"chat": [{"id": 1}]}').size).toBe(0);
    expect(parseStacks("[]").size).toBe(0);
  });

  test("the preview is one line", () => {
    expect(stashPreview({ id: "x", text: "line one\n\n  line   two", attachments: [], at: 0 })).toBe(
      "line one line two",
    );
  });
});
