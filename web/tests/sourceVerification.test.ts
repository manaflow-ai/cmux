import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { normalizeRunSpec, type RunSpec } from "../services/runs/spec";
import {
  assertFreestyleSource,
  githubRepositoryUrl,
  parseSourceVerificationReceipt,
  setupExecutionCommand,
  sourceVerificationCommand,
  SourceVerificationError,
} from "../services/runs/sourceVerification";

const digest = "sha256:" + "a".repeat(64);
const commit = "0123456789abcdef0123456789abcdef01234567";
const execFileAsync = promisify(execFile);

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
    expect(command).toContain("workspace=$(mktemp -d \"${HOME:-/home/cmux}/.cmux-run-XXXXXX\")");
    expect(command).toContain("trap 'if [ \"$cleanup\" -eq 1 ]; then rm -rf -- \"$workspace\"; fi' EXIT");
    expect(command).toContain("node - \"$workspace/.cmux/setup.json\" \"$workspace\"");
    expect(command).toContain("# CMUX_VARIANT_EXECUTION");
    expect(command).toContain("printf 'cmux-source-verified commit=%s setup=%s workspace=%s\\n'");
    expect(command).toContain("cmux-run:run-id:attempt-id:completed");
  });

  test("accepts an exact guest receipt and rejects mismatches", () => {
    const runSpec = spec();
    const stdout = `cmux-setup-completed steps=0\ncmux-source-verified commit=${commit} setup=${digest} workspace=/home/cmux/.cmux-run-test\ncmux-run:run:attempt:completed\n`;
    expect(parseSourceVerificationReceipt(stdout, runSpec)).toEqual({ commit, setupManifestDigest: digest, setupStepCount: 0, workspacePath: "/home/cmux/.cmux-run-test" });
    expect(() => parseSourceVerificationReceipt(stdout.replace(commit, "f".repeat(40)), runSpec)).toThrow(/checkout commit/);
    expect(() => parseSourceVerificationReceipt(stdout.replace(digest, "sha256:" + "b".repeat(64)), runSpec)).toThrow(/setup manifest/);
  });

  test("executes the checked-in setup schema and emits a separate completion receipt", async () => {
    const workspace = await mkdtemp(join(tmpdir(), "cmux-run-setup-"));
    await mkdir(join(workspace, ".cmux"));
    const manifest = `${JSON.stringify({ schema: "cmux.setup/v1", version: 1, steps: [{ id: "fixture", command: "printf ready > setup-receipt.txt" }] })}\n`;
    const manifestPath = join(workspace, ".cmux", "setup.json");
    await writeFile(manifestPath, manifest);
    const setupDigest = `sha256:${createHash("sha256").update(manifest).digest("hex")}`;
    const { stdout } = await execFileAsync("/bin/sh", ["-eu", "-c", setupExecutionCommand(workspace, setupDigest).join("\n")]);
    expect(stdout).toContain("cmux-setup-completed steps=1");
    expect(await readFile(join(workspace, "setup-receipt.txt"), "utf8")).toBe("ready");
  });

  test("requires a setup digest before a cloud-vm attempt can execute", () => {
    const runSpec = spec({ setupManifestDigest: undefined });
    expect(() => assertFreestyleSource(runSpec)).toThrow(/setupManifestDigest/);
    expect(() => sourceVerificationCommand(runSpec, "run:attempt:completed")).toThrow(/setupManifestDigest/);
  });
});
