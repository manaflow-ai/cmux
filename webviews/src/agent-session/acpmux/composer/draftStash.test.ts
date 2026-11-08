import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import {
  STASH_LIMIT,
  STORAGE_KEY,
  moveStash,
  parseStacks,
  resetStashForTests,
  stashDraft,
  stashPreview,
  takeStashed,
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

beforeEach(() => {
  stored.clear();
  resetStashForTests();
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
    stashDraft("one", "a", []);
    stashDraft("one", "b", []);
    stashDraft("two", "c", []);
    const list = parseStacks(stored.get(STORAGE_KEY)).get("one") ?? [];
    const olderId = list.find((entry) => entry.text === "a")?.id;
    expect(takeStashed("one", olderId)?.text).toBe("a");
    expect(takeStashed("one", "no-such-id")).toBeUndefined();
    expect(takeStashed("two")?.text).toBe("c");
    expect(takeStashed("one")?.text).toBe("b");
  });

  test("the stack holds at most STASH_LIMIT drafts, the oldest let go", () => {
    for (let index = 0; index < STASH_LIMIT + 2; index += 1) stashDraft("chat", `draft ${index}`, []);
    const texts: string[] = [];
    for (let entry = takeStashed("chat"); entry; entry = takeStashed("chat")) texts.push(entry.text);
    expect(texts.length).toBe(STASH_LIMIT);
    expect(texts[0]).toBe(`draft ${STASH_LIMIT + 1}`);
    expect(texts.at(-1)).toBe("draft 2");
  });

  test("a reload keeps the stacks; a large entry is stored without its attachments", () => {
    stashDraft("chat", "small", [image("s")]);
    stashDraft("chat", "large", [image("l", 400 * 1024)]);
    resetStashForTests();
    const back = parseStacks(stored.get(STORAGE_KEY));
    const list = back.get("chat") ?? [];
    expect(list.map((entry) => entry.text)).toEqual(["large", "small"]);
    expect(list[0]!.attachments).toEqual([]);
    expect(list[1]!.attachments.map((chip) => chip.id)).toEqual(["s"]);
    expect(takeStashed("chat")?.text).toBe("large");
  });

  test("a new chat's stack follows it to its session", () => {
    stashDraft("new", "before the session", []);
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
    expect(stashPreview({ id: "x", text: "line one\n\n  line   two", attachments: [], at: 0 })).toBe("line one line two");
  });
});
