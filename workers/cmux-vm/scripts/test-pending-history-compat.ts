/** Actual previous writers remain discoverable after an upgrade or rollback. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newVmCreationKey, newVmId } from "../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";

const baseline = "da42cac5dce3899757ac2b4ce9109b12a002c3ed";
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
const fixture = new URL(`../src/limits/.pending-history-compat-${crypto.randomUUID()}.ts`, import.meta.url);
writeFileSync(fixture, source.stdout);
try {
  const previous = await import(fixture.href);
  const storage = memoryLedgerStorage(), current = new TenantLedger(storage), old = new previous.TenantLedger(storage);
  for (let n = 0; n < 2; n++) {
    const key = `old-${n}`, vmId = newVmId(), generated = { key: newVmCreationKey(), cursor: String(n).repeat(64), scope: "tenant",
      createdBy: "key:owner", createdAt: new Date(1_800_000_000_000 + n).toISOString(), displayName: null, labels: {}, operation: "create" };
    await old.begin(key, "request", 0, undefined, generated);
    await old.reserve("vm", 3, 0, 0, `held-${n}`);
    await old.advance(key, { phase: "creating", vmId, reservationId: `held-${n}`, context: "context", createdBy: "key:owner", dispatch: { state: "sent", token: "send" } }, 1);
    const page = await current.listGenerated("tenant", undefined, 50, true);
    assert.equal(page.pendingIndex, "ready");
    assert.equal(page.items[0]?.key, generated.key);
    assert.equal(page.items.length, n + 1);
    // A previous writer may still update its journal and must preserve the new slot binding.
    await old.abandon(key, 2);
    assert.equal((await current.listGenerated("tenant", undefined, 50, true)).items.length, n + 1);
  }
  console.log("pending history compatibility: slots from the actual previous writer are discovered even after an earlier completed backfill");
} finally { unlinkSync(fixture); }
