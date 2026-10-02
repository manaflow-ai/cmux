import { describe, expect, test } from "bun:test";
import { composerDraft, seededText } from "./composerDraft";
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
});
