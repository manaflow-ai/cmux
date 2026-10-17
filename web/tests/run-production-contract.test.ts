import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { getTableConfig } from "drizzle-orm/pg-core";
import { runAttempts, runSecretLeases, runs } from "../db/schema";
import { CloudVmRunAdapter } from "../services/vms/cloudVmRunAdapter";
import { planAttemptBatches } from "../services/runs/dogfood";

const migration = readFileSync(new URL(
  "../db/migrations/20261017030000_run_spec_and_secret_leases/migration.sql",
  import.meta.url,
), "utf8").replace(/\s+/g, " ");

describe("Run production contract", () => {
  test("admission plans never exceed the requested concurrent worker count", () => {
    expect(planAttemptBatches([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(() => planAttemptBatches([1], 0)).toThrow();
  });

  test("persists the immutable spec digest and project-scoped lease table", () => {
    expect(getTableConfig(runs).columns.map((column) => column.name)).toEqual(expect.arrayContaining(["spec_digest", "spec"]));
    expect(getTableConfig(runAttempts).columns.map((column) => column.name)).toContain("setup_manifest_digest");
    expect(getTableConfig(runSecretLeases).columns.map((column) => column.name)).toEqual(expect.arrayContaining(["run_id", "attempt_id", "owner_team_id", "secret_ref", "lease_hash", "expires_at", "revoked_at"]));
    expect(migration).toContain('ADD COLUMN "spec_digest" text');
    expect(migration).toContain('CREATE TABLE "run_secret_leases"');
    expect(migration).toContain('ADD COLUMN "setup_manifest_digest" text');
    expect(migration).toContain('"owner_team_id" text NOT NULL');
  });

  test("Freestyle verification and lease installation never put capabilities in commands or receipts", async () => {
    const calls: Array<{ command: string; stdin?: unknown }> = [];
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command, options) => {
        calls.push({ command, stdin: options?.stdin?.toJSON() });
        if (command.includes(" fetch ")) return { exitCode: 0, stdout: JSON.stringify({ kind: "source.verified", commit: "a".repeat(40) }), stderr: "" };
        if (command.includes("sha256sum")) return { exitCode: 0, stdout: JSON.stringify({ kind: "setup.verified", digest: `sha256:${"b".repeat(64)}` }), stderr: "" };
        return { exitCode: 0, stdout: JSON.stringify({ kind: "secret-leases.installed", path: "/tmp/cmux-run-secret-leases/run_1/attempt_1.json" }), stderr: "" };
      },
    });
    await adapter.verifySource({ vmId: "vm_1", repository: "manaflow-ai/cmux-next", commit: "a".repeat(40), workspacePath: "/workspace/run" });
    await adapter.verifySetup({ vmId: "vm_1", workspacePath: "/workspace/run", setupManifestDigest: `sha256:${"b".repeat(64)}` });
    await adapter.installSecretLeases({ vmId: "vm_1", runId: "run_1", attemptId: "attempt_1", leases: [{ secretRef: "team/project/github", token: "opaque-capability", expiresAt: new Date("2026-10-17T00:05:00Z") }] });
    expect(calls[0]?.command).toContain("checkout --detach");
    expect(calls[0]?.command).not.toContain("opaque-capability");
    expect(calls[2]?.stdin).toBe("[redacted]");
    expect(calls[2]?.command).not.toContain("opaque-capability");
  });
});
