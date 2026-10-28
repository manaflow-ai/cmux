import { describe, expect, test } from "bun:test";
import { normalizeRunSpec, runSpecDigest } from "../services/runs/legacy/spec";

const digest = "sha256:" + "a".repeat(64);

function spec(overrides: Record<string, unknown> = {}) {
  return {
    schema: "cmux.run/v1",
    operationId: "dogfood-run",
    source: { repository: "manaflow-ai/cmux", commit: "0123456789abcdef0123456789abcdef01234567", setupManifestDigest: digest },
    intent: { digest },
    recipe: { id: "default", version: 1 },
    variants: [{ id: "one", label: "One", instructionDigest: digest }],
    workspace: { kind: "ephemeral" },
    resources: { maxAttempts: 1, maxConcurrent: 1, wallTimeoutMs: 60_000, retainMs: 0 },
    routing: { executionProvider: "cloud-vm", backend: "auto" },
    capabilities: { secretRefs: [] },
    checks: [],
    policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
    ...overrides,
  };
}

describe("RunSpec", () => {
  test("normalizes the public secret-free contract and produces a stable digest", () => {
    const normalized = normalizeRunSpec(spec());
    expect(normalized.schema).toBe("cmux.run/v1");
    expect(runSpecDigest(normalized)).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(runSpecDigest(normalized)).toBe(runSpecDigest(normalizeRunSpec(spec())));
  });

  test("rejects provider credential values", () => {
    expect(() => normalizeRunSpec(spec({ capabilities: { secretRefs: [], apiKey: "do-not-store" } }))).toThrow(/must be a reference/);
  });

  test("requires exact source checkout and setup inputs", () => {
    expect(() => normalizeRunSpec(spec({ source: { repository: "manaflow-ai/cmux" } }))).toThrow(/source\.commit or source\.archiveDigest/);
    expect(() => normalizeRunSpec(spec({ source: { repository: "manaflow-ai/cmux", commit: "not-a-sha" } }))).toThrow(/40-character/);
  });
});
