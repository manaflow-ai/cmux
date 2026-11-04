// l10n-allow-file: test fixture prompts, not shipped UI.
// A subagent's draft outlives its composer and its page (review of #33280, F1 and F2): a send that
// fails after the composer it came from is gone reaches the one opened again, a reloaded page finds
// the draft in storage, and one the storage refuses holds the page.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { afterFailedSend } from "./SubagentComposer";
import {
  keepSubagentDraft,
  resetSubagentDraftsForTests,
  restoreSubagentDraft,
  subagentDraft,
  subagentDraftUnsaved,
  subscribeSubagentDraft,
  type Draft,
} from "./subagentDrafts";

/// An in-memory localStorage that can refuse writes, as an over-quota one does.
class FakeStorage {
  items = new Map<string, string>();
  refuse = false;
  get length() {
    return this.items.size;
  }
  key(index: number) {
    return [...this.items.keys()][index] ?? null;
  }
  getItem(key: string) {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string) {
    if (this.refuse) throw new Error("QuotaExceededError");
    this.items.set(key, value);
  }
  removeItem(key: string) {
    this.items.delete(key);
  }
}

const KEY = "chat-1\u0000agent-1";
const draft = (text: string): Draft => ({ text, attachments: [] });
let storage: FakeStorage;
let previous: unknown;

beforeEach(() => {
  previous = (globalThis as { localStorage?: unknown }).localStorage;
  storage = new FakeStorage();
  Object.defineProperty(globalThis, "localStorage", {
    value: storage,
    configurable: true,
    writable: true,
  });
  resetSubagentDraftsForTests();
});

afterEach(() => {
  Object.defineProperty(globalThis, "localStorage", {
    value: previous,
    configurable: true,
    writable: true,
  });
  resetSubagentDraftsForTests();
});

describe("subagent drafts", () => {
  test("a send that fails after its composer is gone reaches the composer opened again", () => {
    // Sent from the first composer, which then unmounts (the person opened the chat).
    keepSubagentDraft(KEY, draft(""));
    // The same subagent's pane opens again before the send fails; its composer subscribes.
    const shown: Draft[] = [];
    const stop = subscribeSubagentDraft(KEY, (restored) => shown.push(restored));
    keepSubagentDraft(KEY, draft("typed since"));
    // The late failure.
    restoreSubagentDraft(
      KEY,
      afterFailedSend(subagentDraft(KEY), {
        typed: "the message",
        held: [],
        message: "the message",
      }),
    );
    expect(shown).toEqual([draft("the message\n\ntyped since")]);
    expect(subagentDraft(KEY)).toEqual(draft("the message\n\ntyped since"));
    stop();
  });

  test("another subagent's composer is not handed the failure", () => {
    const shown: Draft[] = [];
    const stop = subscribeSubagentDraft("chat-1\u0000agent-2", (restored) => shown.push(restored));
    restoreSubagentDraft(KEY, draft("for agent 1"));
    expect(shown).toEqual([]);
    stop();
  });

  test("a page loaded again finds the draft in storage", () => {
    keepSubagentDraft(KEY, draft("half a thought"));
    resetSubagentDraftsForTests();
    expect(subagentDraft(KEY)).toEqual(draft("half a thought"));
    expect(subagentDraftUnsaved()).toBe(false);
  });

  test("an emptied draft is forgotten in storage too", () => {
    keepSubagentDraft(KEY, draft("x"));
    keepSubagentDraft(KEY, draft(""));
    resetSubagentDraftsForTests();
    expect(subagentDraft(KEY)).toEqual(draft(""));
    expect(storage.items.size).toBe(0);
  });

  test("a draft the storage refuses stays in memory and holds the page until it is stored or cleared", () => {
    storage.refuse = true;
    keepSubagentDraft(KEY, draft("a huge paste"));
    expect(subagentDraft(KEY)).toEqual(draft("a huge paste"));
    expect(subagentDraftUnsaved()).toBe(true);
    keepSubagentDraft(KEY, draft(""));
    expect(subagentDraftUnsaved()).toBe(false);
    keepSubagentDraft(KEY, draft("again"));
    storage.refuse = false;
    keepSubagentDraft(KEY, draft("again, smaller"));
    expect(subagentDraftUnsaved()).toBe(false);
  });

  test("a draft nobody came back to in two weeks is forgotten when a page loads", () => {
    const now = Date.UTC(2026, 10, 4);
    keepSubagentDraft(KEY, draft("old"), now - 15 * 86_400_000);
    keepSubagentDraft("chat-2\u0000agent-1", draft("recent"), now - 86_400_000);
    resetSubagentDraftsForTests();
    expect(subagentDraft(KEY, now)).toEqual(draft(""));
    expect(subagentDraft("chat-2\u0000agent-1", now)).toEqual(draft("recent"));
    expect(storage.items.size).toBe(1);
  });
});
