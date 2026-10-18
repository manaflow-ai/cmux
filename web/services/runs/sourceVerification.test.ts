import { describe, expect, test } from "bun:test";
import { normalizeRunSpec, type RunSpec } from "./spec";
import {
  assertFreestyleSource,
  githubRepositoryUrl,
  parseSourceVerificationReceipt,
  sourceVerificationCommand,
  SourceVerificationError,
} from "./sourceVerification";

const digest = "sha256:" + "a".repeat(64);
const commit = "0123456789abcdef0123456789abcdef01234567";

function spec(overrides: Partial<RunSpec["source"]> = {}): RunSpec {
  return normalizeRunSpec({
    schema: "cmux.run/v1",
    operationId: "source-verification-test",
    source: { repository: "manaflow-ai/cmux", commit, setupManifestDigest: digest, ...overrides },
    intent: { digest },
    recipe: { id: "default", version: 1 },
    variants: [{ id: "one", label: "One", instructionDigest: digest }],
    workspace: { kind: "ephemeral" },
    resources: { maxAttempts: 1, maxConcurrent: 1, wallTimeoutMs: 60_000, retainMs: 0 },
    routing: { executionProvider: "cloud-vm", backend: "freestyle" },
    capabilities: { secretRefs: [] },
    checks: [],
    policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
  });
}

describe("Freestyle source verification", () => {
  test("normalizes only public GitHub repository forms", () => {
    expect(githubRepositoryUrl("manaflow-ai/cmux")).toBe("https://github.com/manaflow-ai/cmux.git");
    expect(githubRepositoryUrl("https://github.com/manaflow-ai/cmux.git")).toBe("https://github.com/manaflow-ai/cmux.git");
    expect(() => githubRepositoryUrl("https://evil.example/cmux.git")).toThrow(SourceVerificationError);
  });

  test("builds a bounded immutable checkout and setup digest check", () => {
    const command = sourceVerificationCommand(spec(), "run-id:attempt-id:completed");
    expect(command).toContain("fetch -q --depth=1 origin '0123456789abcdef0123456789abcdef01234567'");
    expect(command).toContain("sha256sum '/tmp/cmux-run-run-id-attempt-id-completed/.cmux/setup.json'");
    expect(command).toContain("printf 'cmux-source-verified commit=%s setup=%s\\n'");
    expect(command).toContain("cmux-run:run-id:attempt-id:completed");
  });

  test("accepts an exact guest receipt and rejects mismatches", () => {
    const runSpec = spec();
    const stdout = `cmux-source-verified commit=${commit} setup=${digest}\ncmux-run:run:attempt:completed\n`;
    expect(parseSourceVerificationReceipt(stdout, runSpec)).toEqual({ commit, setupManifestDigest: digest });
    expect(() => parseSourceVerificationReceipt(stdout.replace(commit, "f".repeat(40)), runSpec)).toThrow(/checkout commit/);
    expect(() => parseSourceVerificationReceipt(stdout.replace(digest, "sha256:" + "b".repeat(64)), runSpec)).toThrow(/setup manifest/);
  });

  test("requires a setup digest before a cloud-vm attempt can execute", () => {
    const runSpec = spec({ setupManifestDigest: undefined });
    expect(() => assertFreestyleSource(runSpec)).toThrow(/setupManifestDigest/);
    expect(() => sourceVerificationCommand(runSpec, "run:attempt:completed")).toThrow(/setupManifestDigest/);
  });
});
