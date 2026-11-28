/** Run the actual pre-capture ledger against permanent snapshot operation records. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newSnapshotId, newVmId } from "../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";

const baseline = "5e562ce890c091495b67670bf977b41b94acb8fd";
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
const fixture = new URL(`../src/limits/.snapshot-compat-${crypto.randomUUID()}.ts`, import.meta.url);
writeFileSync(fixture, source.stdout);
try {
  const previous = await import(fixture.href);
  for (const terminal of ["committed", "cancelled"]) {
    const storage = memoryLedgerStorage(), current = new TenantLedger(storage), old = new previous.TenantLedger(storage);
    const id = newSnapshotId(), intent = { id, sourceVmId: newVmId(), displayName: null, labels: {}, createdBy: "key:owner",
      createdAt: "2026-10-18T00:00:00Z", ttlSeconds: null, autoDeleteSeconds: null };
    await current.snapshotCapture({ op: "begin", key: "capture", fingerprint: "request", intent, nonce: "lease" }, 0);
    await assert.rejects(old.begin("capture", "request", 100_000_000), /unrecognized/);
    await current.reserve("snapshot", 1, 0, 0, "held");
    await current.snapshotCapture({ op: "prepare", id, nonce: "lease", reservationId: "held", probe: { context: "context", source: "source", stamp: "stamp" } }, 1);
    await current.snapshotCapture({ op: "send", id, token: "send" }, 2);
    await assert.rejects(old.begin("capture", "request", 100_000_000), /unrecognized/);
    if (terminal === "committed") await current.snapshotCapture({ op: "commit", id }, 3);
    else { await current.snapshotCapture({ op: "cancel", id }, 3); await current.snapshotCapture({ op: "cancelled", id }, 4); }
    await old.abandon("capture", 100_000_000);
    await old.begin("sweep", "different", 100_000_000);
    await assert.rejects(old.begin("capture", "request", 100_000_000), /unrecognized/);
    const result = await current.snapshotCapture({ op: "get", id }, 100_000_000);
    assert.equal(result.state, "record");
    if (result.state === "record") assert.equal(result.record.state, terminal);
  }
  console.log("snapshot compatibility: pinned previous ledger cannot replay, overwrite or expire retained captures");
} finally { unlinkSync(fixture); }
