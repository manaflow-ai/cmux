import { describe, expect, test } from "bun:test";
import {
  MAX_VAULT_BATCH_ITEMS,
  normalizeAgent,
  normalizeRelPath,
  normalizeSha256,
  validateVaultBatch,
} from "../services/vault/validation";

const validSha = "a".repeat(64);

describe("vault validation", () => {
  test("allows only supported agents", () => {
    expect(normalizeAgent("codex")).toEqual({ ok: true, value: "codex" });
    expect(normalizeAgent("claude")).toEqual({ ok: true, value: "claude" });
    expect(normalizeAgent("pi")).toEqual({ ok: true, value: "pi" });
    expect(normalizeAgent("opencode")).toEqual({ ok: false, error: "invalid_agent" });
  });

  test("rejects relative path traversal and absolute paths", () => {
    expect(normalizeRelPath("sessions/2026/a.jsonl")).toEqual({
      ok: true,
      value: "sessions/2026/a.jsonl",
    });
    expect(normalizeRelPath("../secrets.jsonl")).toEqual({ ok: false, error: "invalid_rel_path" });
    expect(normalizeRelPath("sessions/../secrets.jsonl")).toEqual({ ok: false, error: "invalid_rel_path" });
    expect(normalizeRelPath("/tmp/session.jsonl")).toEqual({ ok: false, error: "invalid_rel_path" });
    expect(normalizeRelPath("sessions\\bad.jsonl")).toEqual({ ok: false, error: "invalid_rel_path" });
  });

  test("validates sha256 hex", () => {
    expect(normalizeSha256(validSha)).toEqual({ ok: true, value: validSha });
    expect(normalizeSha256("g".repeat(64))).toEqual({ ok: false, error: "invalid_sha256" });
    expect(normalizeSha256("a".repeat(63))).toEqual({ ok: false, error: "invalid_sha256" });
  });

  test("caps batch size", () => {
    const item = {
      agent: "codex",
      agentSessionId: "11111111-1111-4111-8111-111111111111",
      relPath: "sessions/2026/a.jsonl",
      sha256: validSha,
      sizeBytes: 10,
      compressedSizeBytes: 9,
    };
    expect(validateVaultBatch({ items: [item] }).ok).toBe(true);
    expect(validateVaultBatch({ items: Array.from({ length: MAX_VAULT_BATCH_ITEMS + 1 }, () => item) })).toEqual({
      ok: false,
      error: "invalid_batch_size",
    });
  });
});
