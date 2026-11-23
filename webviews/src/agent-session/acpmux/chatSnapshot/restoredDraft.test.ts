// The prompt a restored chat's copy showed stands in for acpmux's draft on the live composer's first
// frame (Leo, 2026-11-22: "composer dips down then goes back up"), for that chat only, until a read
// of acpmux's answered.
import { afterEach, describe, expect, test } from "bun:test";
import {
  replacedRestoredDraft,
  resetRestoredDraftsForTests,
  restoredDraft,
  snapshotDraft,
  SNAPSHOT_DRAFT_MAX_CHARS,
} from "./restoredDraft";

const globals = globalThis as unknown as Record<string, unknown>;
const hadWindow = "window" in globalThis;

/// As the host's `__snapshot/chat.js` serves what it kept (AgentPaneChatSnapshots.swift): the copy,
/// and the prompt it (or the miss in its place) carried, only when there is one.
function serve(chat: string | null, copy: unknown): void {
  if (!hadWindow) globals.window = globalThis;
  globals.__cmuxRestoredChat = chat;
  globals.__cmuxChatSnapshot = (copy as { html?: unknown } | null)?.html ? copy : null;
  const draft = (copy as { draft?: unknown } | null)?.draft;
  if (draft) globals.__cmuxRestoredDraft = draft;
  else delete globals.__cmuxRestoredDraft;
}

afterEach(() => {
  delete globals.__cmuxRestoredChat;
  delete globals.__cmuxChatSnapshot;
  delete globals.__cmuxRestoredDraft;
  if (!hadWindow) delete globals.window;
  resetRestoredDraftsForTests();
});

describe("restoredDraft", () => {
  test("the restored chat's copy names its prompt", () => {
    serve("chat-a", { html: "<main></main>", draft: "half a thought\n\nand more" });
    expect(restoredDraft("chat-a")).toBe("half a thought\n\nand more");
  });

  test("with no copy (one too large to keep), the prompt kept in its place stands in", () => {
    serve("chat-a", { miss: "too large", draft: "kept without a copy" });
    expect(globals.__cmuxChatSnapshot).toBeNull();
    expect(restoredDraft("chat-a")).toBe("kept without a copy");
  });

  test("another chat, no copy, or an empty prompt stand in nothing", () => {
    serve("chat-a", { html: "<main></main>", draft: "for a" });
    expect(restoredDraft("chat-b")).toBeUndefined();
    expect(restoredDraft(undefined)).toBeUndefined();
    serve("chat-a", null);
    expect(restoredDraft("chat-a")).toBeUndefined();
    serve("chat-a", { html: "<main></main>", draft: "  \n" });
    expect(restoredDraft("chat-a")).toBeUndefined();
    serve("chat-a", { html: "<main></main>" });
    expect(restoredDraft("chat-a")).toBeUndefined();
  });

  test("once acpmux's read answered, the copy's prompt is never drawn again on the page", () => {
    serve("chat-a", { html: "<main></main>", draft: "for a" });
    replacedRestoredDraft("chat-a");
    expect(restoredDraft("chat-a")).toBeUndefined();
  });

  test("a copy carries a prompt only when it has one and it is not a pasted log", () => {
    expect(snapshotDraft("text")).toBe("text");
    expect(snapshotDraft("")).toBeUndefined();
    expect(snapshotDraft(" \n ")).toBeUndefined();
    expect(snapshotDraft(undefined)).toBeUndefined();
    expect(snapshotDraft("x".repeat(SNAPSHOT_DRAFT_MAX_CHARS + 1))).toBeUndefined();
  });
});
