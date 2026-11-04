// l10n-allow-file: test fixture prompts, not shipped UI.
// A subagent's draft outlives its composer and its page (review of #33280, F1 and F2): a send that
// fails after the composer it came from is gone reaches the one opened again, a reloaded page finds
// the draft in storage, and one the storage refuses holds the page.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { afterFailedSend } from "./SubagentComposer";
import { inlineToken, type ComposerAttachment } from "../attachments";
import {
  draftMessage,
  keepSubagentDraft,
  resetSubagentDraftsForTests,
  restoreSubagentDraft,
  subagentDraft,
  subagentDraftUnsaved,
  subscribeSubagentDraft,
  wakeIntoSubagentDrafts,
  wakeSubagentDrafts,
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

  test("a quit hands the host each draft as text, and the next page takes them back", () => {
    keepSubagentDraft(KEY, {
      text: `see ${inlineToken("p1")} and fix`,
      attachments: [{ id: "p1", kind: "pasted", text: "the stack trace" } as unknown as ComposerAttachment],
    });
    keepSubagentDraft("chat-1\u0000agent-2", draft("second"));
    const wake = wakeSubagentDrafts();
    // The pasted chip's text goes in its place: the relay is text only.
    expect(wake).toEqual({ [KEY]: "see the stack trace and fix", "chat-1\u0000agent-2": "second" });
    // The app quits: its pages' storage is gone with it.
    storage.items.clear();
    resetSubagentDraftsForTests();
    wakeIntoSubagentDrafts(wake);
    expect(subagentDraft("chat-1\u0000agent-2")).toEqual(draft("second"));
    expect(subagentDraft(KEY)).toEqual(draft("see the stack trace and fix"));
  });

  test("a draft the page still keeps wins over the woken copy", () => {
    keepSubagentDraft(KEY, draft("typed after the release"));
    wakeIntoSubagentDrafts({ [KEY]: "older" });
    expect(subagentDraft(KEY)).toEqual(draft("typed after the release"));
  });

  test("the wake state carries no more than about a megabyte of drafts", () => {
    keepSubagentDraft(KEY, draft("x".repeat(900_000)));
    keepSubagentDraft("chat-1\u0000agent-2", draft("y".repeat(900_000)));
    const wake = wakeSubagentDrafts() ?? {};
    // The newest draft goes; the older one stays out rather than push the tab past the host's cap.
    expect(Object.keys(wake)).toEqual(["chat-1\u0000agent-2"]);
  });

  test("an empty store hands the host nothing", () => {
    expect(wakeSubagentDrafts()).toBeUndefined();
  });

  test("a draft's message puts each pasted chip in its place, and a loose one after", () => {
    const chips = [
      { id: "p1", kind: "pasted", text: "A" },
      { id: "p2", kind: "pasted", text: "B" },
      { id: "i1", kind: "image", data: "iVBO" },
    ] as unknown as ComposerAttachment[];
    expect(draftMessage({ text: `x ${inlineToken("p1")} y`, attachments: chips })).toBe("x A y\n\nB");
  });
});
