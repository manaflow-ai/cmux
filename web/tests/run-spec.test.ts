import { describe, expect, test } from "bun:test";
import {
  RunSpecValidationError,
  normalizeRunSpec,
  redactedRunSpec,
  runSpecDigest,
} from "../services/runs/spec";

const SHA = "sha256:" + "a".repeat(64);
const COMMIT = "b".repeat(40);

function fixture(overrides: Record<string, unknown> = {}) {
  return {
    schema: "cmux.run/v1",
    operationId: "dogfood-run-001",
    source: {
      repository: "manaflow-ai/cmux-next",
      ref: "main",
      commit: COMMIT,
      setupManifestDigest: SHA,
      imageDigest: SHA,
    },
    intent: { digest: SHA },
    recipe: { id: "ui-tournament", version: 1 },
    variants: [
      { id: "alpha", label: "alpha", instructionDigest: SHA },
      { id: "beta", label: "beta", instructionDigest: SHA },
    ],
    workspace: { kind: "persistent", desiredKey: "dogfood-box" },
    resources: { maxAttempts: 2, maxConcurrent: 2, memoryClass: "standard", cpuClass: "standard" },
    routing: { backend: "freestyle" },
    capabilities: { secretRefs: ["team/staging/github"], networkProfile: "private-egress" },
    checks: ["source.verified", "setup.verified"],
    policy: { mode: "thunderdome", humanApprovalRequired: true, evidenceKinds: ["screenshot", "patch"] },
    ...overrides,
  };
}

describe("RunSpec v1", () => {
  test("normalizes a bounded fan-out spec and produces a stable digest", () => {
    const spec = normalizeRunSpec(fixture());
    expect(spec.schema).toBe("cmux.run/v1");
    expect(spec.resources.maxConcurrent).toBe(2);
    expect(spec.capabilities.secretRefs).toEqual(["team/staging/github"]);
    expect(runSpecDigest(spec)).toMatch(/^sha256:[0-9a-f]{64}$/);

    const reordered = normalizeRunSpec({
      ...fixture(),
      policy: { evidenceKinds: ["screenshot", "patch"], humanApprovalRequired: true, mode: "thunderdome" },
      source: { imageDigest: SHA, setupManifestDigest: SHA, commit: COMMIT, ref: "main", repository: "manaflow-ai/cmux-next" },
    });
    expect(runSpecDigest(reordered)).toBe(runSpecDigest(spec));
    expect(redactedRunSpec(spec)).toEqual(spec);
  });

  test("rejects secret values while allowing secret references", () => {
    expect(() => normalizeRunSpec(fixture({ apiKey: "do-not-print" }))).toThrow(RunSpecValidationError);
    const spec = normalizeRunSpec(fixture());
    expect(JSON.stringify(redactedRunSpec(spec))).not.toContain("do-not-print");
  });

  test("rejects malformed source, duplicate variants, and invalid concurrency", () => {
    expect(() => normalizeRunSpec(fixture({ source: { commit: "bad\ncommit" } }))).toThrow(RunSpecValidationError);
    expect(() => normalizeRunSpec(fixture({ variants: [fixture().variants[0], fixture().variants[0]] }))).toThrow(RunSpecValidationError);
    expect(() => normalizeRunSpec(fixture({ resources: { maxAttempts: 2, maxConcurrent: 3 } }))).toThrow(RunSpecValidationError);
  });
});
