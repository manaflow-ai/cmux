import { describe, expect, test } from "bun:test";
import { composerDraft, readDurableDraft, seededText, writePersistedDraft } from "./composerDraft";
import { newSessionParams } from "./direct";

describe("a chat opened from another tab", () => {
  test("takes a non-empty draft from the handshake", () => {
    expect(composerDraft("https://example.com\n\n")).toBe("https://example.com\n\n");
    expect(composerDraft("  \n")).toBeUndefined();
    expect(composerDraft(undefined)).toBeUndefined();
    expect(composerDraft(42)).toBeUndefined();
  });

  test("never replaces what the user typed", () => {
    expect(seededText("", "draft")).toBe("draft");
    expect(seededText("mine", "draft")).toBe("mine");
    expect(seededText("", undefined)).toBe("");
  });

  test("creates its session in the inherited cwd", () => {
    expect(newSessionParams({ cwd: "/work/app" }, "claude")).toEqual({
      cwd: "/work/app",
      mcpServers: [],
      _meta: { acpmux: { harness: "claude" } },
    });
    expect(newSessionParams({})).toEqual({ mcpServers: [], _meta: { acpmux: { harness: undefined } } });
  });

  test("uses the connected daemon action for durable drafts", async () => {
    const previous = (globalThis as { window?: unknown }).window;
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    (globalThis as { window?: unknown }).window = {
      cmuxAcpmuxActions: {
        "chat.readDraft": async (params: Record<string, unknown>) => {
          calls.push({ method: "read", params });
          return { draft: "daemon draft" };
        },
        "chat.writeDraft": async (params: Record<string, unknown>) => {
          calls.push({ method: "write", params });
          return { draft: params.text };
        },
      },
    };
    try {
      expect(await readDurableDraft("session-1")).toBe("daemon draft");
      writePersistedDraft("session-1", "saved by daemon");
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(calls).toEqual([
        { method: "read", params: { sessionId: "session-1" } },
        { method: "write", params: { sessionId: "session-1", text: "saved by daemon" } },
      ]);
    } finally {
      (globalThis as { window?: unknown }).window = previous;
    }
  });
});
