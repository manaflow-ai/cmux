/** The actual previous ledger cannot forget or reopen a fork's capture stage. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newSnapshotId, newVmId } from "../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";

const baseline = "5768d9d8f42af15c83adfa6d1adda35a61900404";
const root = fileURLToPath(new URL("../../../", import.meta.url));
const git = (...args: string[]) => Bun.spawnSync(["git", "-C", root, ...args], { stdout: "pipe", stderr: "pipe" });
// Pass --depth only in an already-shallow checkout; it would make a full clone shallow.
const shallowDepth = git("rev-parse", "--is-shallow-repository").stdout.toString().trim() === "true" ? ["--depth=1"] : [];
let source = git("show", `${baseline}:workers/cmux-vm/src/limits/ledger.ts`);
if (source.exitCode !== 0) {
  assert.equal(git("fetch", "--no-tags", ...shallowDepth, "origin", baseline).exitCode, 0);
  source = git("show", `${baseline}:workers/cmux-vm/src/limits/ledger.ts`);
}
assert.equal(source.exitCode, 0);
const fixture = new URL(`../src/limits/.fork-capture-compat-${crypto.randomUUID()}.ts`, import.meta.url);
writeFileSync(fixture, source.stdout);
try {
  const previous = await import(fixture.href);
  const storage = memoryLedgerStorage(), current = new TenantLedger(storage), old = new previous.TenantLedger(storage);
  const vmId = newVmId(), snapshotId = newSnapshotId();
  await current.begin("fork", "request", 0);
  await current.reserve("vm", 1, 0, 0, "slot");
  await current.advance("fork", { phase: "capturing", vmId, sourceVmId: newVmId(), snapshotId, captureKey: "child",
    reservationId: "slot", createdBy: "key:owner", createdAt: "2026-10-19T00:00:00Z",
    receipt: { id: vmId, displayName: null, labels: {}, idleTimeoutSeconds: 300 } }, 1);
  await assert.rejects(old.begin("fork", "request", 100_000_000), /unrecognized/);
  await old.abandon("fork", 100_000_000);
  await old.begin("sweep", "unrelated", 100_000_000);
  assert.equal((await current.inspect("fork"))?.progress.phase, "capturing");
  assert.deepEqual(await current.reserve("vm", 1, 0, 100_000_000, "other"), { ok: false });
  assert.equal(await current.cancelCreation("fork", vmId), "accepted");
  assert.equal(await current.settleCancellation("fork", vmId), false);
  await current.snapshotCapture({ op: "fence", key: "child", expectedId: null, createdBy: "key:owner", labels: {} }, 100_000_000);
  assert.equal(await current.settleCancellation("fork", vmId), true);
  await assert.rejects(old.begin("fork", "request", 200_000_000), /unrecognized/);
  const record = await current.inspect("fork");
  assert.equal(record?.progress.phase === "capturing" && record.progress.cancelled, true);
  assert.equal((await current.reserve("vm", 1, 0, 200_000_000, "released")).ok, true);
  await current.begin("legacy", "old-request", 0);
  assert.equal(await current.quarantineForkClaim("legacy", 200_000_000), true);
  await old.abandon("legacy", 200_000_000);
  await old.begin("sweep-again", "unrelated", 200_000_000);
  assert.deepEqual(await old.begin("legacy", "old-request", 200_000_000), { state: "in_progress" });
  await current.begin("live", "busy", 200_000_000);
  assert.equal(await current.quarantineForkClaim("live", 200_000_000), false);
  console.log("fork capture compatibility: previous ledger cannot expire pending or cancelled forks; quota stays held until the child is fenced");
} finally { unlinkSync(fixture); }
