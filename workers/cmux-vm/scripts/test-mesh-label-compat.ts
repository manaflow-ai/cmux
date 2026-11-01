/** Execute the previous mesh engine against labelled intents during a rolling update. */
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newMeshId } from "../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../src/limits/ledger.ts";

const baseline = "59035d21391f05151380e3d0447735998bd1b34f";
const root = fileURLToPath(new URL("../../../", import.meta.url));
const git = (...args: string[]) => Bun.spawnSync(["git", "-C", root, ...args], { stdout: "pipe", stderr: "pipe" });
let source = git("show", `${baseline}:workers/cmux-vm/src/limits/mesh-creation.ts`);
if (source.exitCode !== 0) {
  assert.equal(git("fetch", "--no-tags", "--depth=1", "origin", baseline).exitCode, 0);
  source = git("show", `${baseline}:workers/cmux-vm/src/limits/mesh-creation.ts`);
}
assert.equal(source.exitCode, 0);
const path = new URL(`../src/limits/.mesh-label-compat-${crypto.randomUUID()}.ts`, import.meta.url);
writeFileSync(path, new TextDecoder().decode(source.stdout));
try {
  const previous = await import(path.href);
  const storage = memoryLedgerStorage(), current = new TenantLedger(storage), meshId = newMeshId();
  const key = "1".repeat(64), fingerprint = "2".repeat(64), holder = "worker";
  const labels = { role: "cloud", cmux_mesh_creation: key };
  const intent = { key, fingerprint, meshId, holder, createdBy: "service:cloud", displayName: null };
  await assert.rejects(previous.meshCreation(storage, { op: "begin-labelled", ...intent, labels }, 0), /invalid mesh creation command/);
  assert.equal(await storage.get(`mesh-create-v1:${key}`), undefined);
  assert.equal((await current.meshCreation({ op: "begin-labelled", ...intent, labels }, 1)).state, "record");
  await previous.meshCreation(storage, { op: "abandon", key, meshId, holder }, 2);
  const oldReply = await previous.meshCreation(storage, { op: "begin", ...intent }, 3);
  assert.equal(oldReply.state, "record");
  assert.deepEqual(oldReply.record.labels, labels);
  await previous.meshCreation(storage, { op: "abandon", key, meshId, holder }, 4);
  const resumed = await current.meshCreation({ op: "begin-labelled", ...intent, labels }, 5);
  assert.equal(resumed.state, "record");
  if (resumed.state !== "record") throw new Error("missing labelled mesh intent");
  assert.deepEqual(resumed.record.labels, labels);
  assert.deepEqual(await current.meshCreation({ op: "begin", ...intent }, 6), { state: "conflict" });
  console.log(`mesh label compatibility: actual engine at ${baseline} refuses new labelled allocations and preserves existing bindings`);
} finally { unlinkSync(path); }
