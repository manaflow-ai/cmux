/** Run the actual previous ledger against generated-operation storage, including rollback attempts. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { VmCreationKey } from "../src/lib/ids.ts";
import { IDEMPOTENCY_TTL_MS, memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";

const baseline = "7462cb6feaf5930d67d795119fed79a34531697d";
const root = fileURLToPath(new URL("../../../", import.meta.url));
const git = (...args: string[]) => Bun.spawnSync(["git", "-C", root, ...args], { stdout: "pipe", stderr: "pipe" });
// Pass --depth only in an already-shallow checkout; it would make a full clone shallow.
const shallowDepth = git("rev-parse", "--is-shallow-repository").stdout.toString().trim() === "true" ? ["--depth=1"] : [];
const read = () => git("show", `${baseline}:workers/cmux-vm/src/limits/ledger.ts`);
let source = read();
if (source.exitCode !== 0) {
  const fetched = git("fetch", "--no-tags", ...shallowDepth, "origin", baseline);
  if (fetched.exitCode !== 0) throw Error("cannot fetch the pinned previous ledger");
  source = read();
}
if (source.exitCode !== 0) throw Error("cannot read the pinned previous ledger");
const fixture = new URL(`../src/limits/.generated-compat-${crypto.randomUUID()}.ts`, import.meta.url);
writeFileSync(fixture, source.stdout);
try {
  const previous = await import(fixture.href);
  const storage = memoryLedgerStorage(), current = new TenantLedger(storage), old = new previous.TenantLedger(storage);
  const id = "vm_00000000000000000000000001", later = IDEMPOTENCY_TTL_MS * 3;
  await current.begin("generated", "request", 0, undefined, {
    key: VmCreationKey.make("vcr_00000000000000000000000001"), cursor: "0".repeat(64), scope: "tenant",
    createdBy: "key:owner", createdAt: "2026-10-18T00:00:00Z", displayName: null, labels: {}, operation: "create",
  });
  await assert.rejects(old.begin("generated", "request", later), /unrecognized idempotency record/);
  await current.advance("generated", { phase: "snapshotted", snapshotId: "snap_00000000000000000000000001" }, 1);
  await assert.rejects(old.begin("generated", "request", later), /unrecognized idempotency record/);
  await current.reserve("vm", 1, 0, 0, "held");
  await current.advance("generated", { phase: "creating", vmId: id, reservationId: "held", context: "provider", createdBy: "key:owner" }, 2);
  await assert.rejects(old.advance("generated", { phase: "done", vmId: id }, 2), /missing idempotency claim/);
  await assert.rejects(old.begin("generated", "request", later), /unrecognized idempotency record/);
  await current.advance("generated", { phase: "done", vmId: id }, 3);
  await old.abandon("generated", later);
  await old.begin("ordinary-trigger", "request", later);
  await assert.rejects(old.begin("generated", "request", later), /unrecognized idempotency record/);
  assert.deepEqual(await current.begin("generated", "request", later), { state: "resume", progress: { phase: "done", vmId: id } });
  await old.begin("legacy", "request", 0);
  await old.advance("legacy", { phase: "done", vmId: id }, 1);
  assert.deepEqual(await current.begin("legacy", "request", 2), { state: "resume", progress: { phase: "done", vmId: id } });
  console.log("generated creation compatibility: pinned previous ledger refuses protected claims/completions; current replay and legacy reads pass");
} finally {
  unlinkSync(fixture);
}
