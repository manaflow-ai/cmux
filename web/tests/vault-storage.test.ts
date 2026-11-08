import { describe, expect, test } from "bun:test";
import { buildObjectKey } from "../services/vault/storage";

describe("vault storage", () => {
  test("derives object keys under the authenticated user prefix", () => {
    const key = buildObjectKey(
      "user-123",
      "codex",
      "11111111-1111-4111-8111-111111111111",
      "a".repeat(64),
    );
    expect(key).toBe(
      `vault/u/user-123/codex/11111111-1111-4111-8111-111111111111/${"a".repeat(64)}.jsonl.zst`,
    );
  });

  test("sanitizes path separators out of key parts", () => {
    const key = buildObjectKey("user/123", "codex", "../session", "b".repeat(64));
    expect(key.startsWith("vault/u/user_123/")).toBe(true);
    expect(key).not.toContain("../");
  });
});
