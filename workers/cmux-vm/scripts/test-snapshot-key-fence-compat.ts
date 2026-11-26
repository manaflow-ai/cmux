/** Execute the previous capture engine and ledger against a newly fenced key. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { newSnapshotId, newVmId } from "../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";
import { readBaseline } from "./compat-baseline.ts";

const baseline = "03ae98243cc3c419959c61e837c7e28a7378df8c";
const read = (path: string) => readBaseline(baseline, path);
const suffix = crypto.randomUUID(), engineName = `.snapshot-engine-compat-${suffix}.ts`;
const engine = new URL(`../src/limits/${engineName}`, import.meta.url);
const ledger = new URL(`../src/limits/.snapshot-ledger-compat-${suffix}.ts`, import.meta.url);
writeFileSync(engine, read("snapshot-capture.ts"));
writeFileSync(ledger, read("ledger.ts").replace('from "./snapshot-capture.ts"', `from "./${engineName}"`));
try {
  const previous = await import(ledger.href);
  const storage = memoryLedgerStorage(), current = new TenantLedger(storage), old = new previous.TenantLedger(storage);
  await current.snapshotCapture({ op: "fence", key: "closed", expectedId: null, createdBy: "service:cloud", labels: { role: "cloud" } }, 0);
  const intent = { id: newSnapshotId(), sourceVmId: newVmId(), displayName: null, labels: { role: "cloud" },
    createdBy: "service:cloud", createdAt: "2026-10-19T00:00:00Z", ttlSeconds: null, autoDeleteSeconds: null };
  assert.deepEqual(await old.snapshotCapture({ op: "begin", key: "closed", fingerprint: "late", intent, nonce: "late" }, 100_000_000), { state: "mismatch" });
  await assert.rejects(old.begin("closed", "late", 100_000_000), /unrecognized/);
  await old.abandon("closed", 100_000_000);
  await old.begin("sweep", "unrelated", 100_000_000);
  const result = await current.snapshotCapture({ op: "inspect", key: "closed" }, 100_000_000);
  assert.equal(result.state, "fenced");
  console.log(`snapshot key fence compatibility: actual ledger and capture engine at ${baseline} cannot allocate or expire a fenced key`);
} finally { unlinkSync(engine); unlinkSync(ledger); }
