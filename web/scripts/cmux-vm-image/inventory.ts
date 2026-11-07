/**
 * The SBOM and file manifest of a layered bake's image, taken off the per-commit critical path
 * (bake.ts --defer-inventory). The bake snapshots, leaves its builder running and records it as
 * `inventoryVmId` in bake-<name>.json; this reads the builder's tree (the snapshot's: nothing ran on it
 * since), downloads both files into the out dir, merges them into that bake json (the image record the
 * candidate step reads) and deletes the builder. The workflow runs it beside the smoke.
 *
 * Usage (from web/): bun ../images/cmux-vm/inventory.ts --out-dir <dir> [--lock <path>]
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { collectInventory } from "./bake";
import { argValue, deleteVm, freestyleClient, Ledger, StepLog, type Vm } from "./guest";
import { DEFAULT_LOCK_PATH, readInputsLock } from "./lock";

export async function main(argv = process.argv): Promise<number> {
  const outDir = path.resolve(argValue("--out-dir", argv) ?? "");
  const bakeJson = readdirSync(outDir).find((f) => /^bake-.*\.json$/.test(f));
  if (!bakeJson) throw new Error(`no bake-*.json in ${outDir}`);
  const file = path.join(outDir, bakeJson);
  const record = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown> & { name: string; inventoryVmId?: string; lockPath?: string };
  const vmId = record.inventoryVmId;
  if (!vmId) {
    console.log("INVENTORY none: the bake recorded its SBOM and manifest before the snapshot");
    return 0;
  }
  // The bake's own lock (recorded in its json), so a bake from another lock gets its own Syft pin.
  const lock = readInputsLock(path.resolve(argValue("--lock", argv) ?? record.lockPath ?? DEFAULT_LOCK_PATH));
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const L = new StepLog(path.join(outDir, `inventory-${record.name}.log`));
  const vm = freestyleClient().vms.ref(vmId) as unknown as Vm;
  const inventory: Record<string, unknown> = {};
  const t0 = Date.now();
  try {
    await collectInventory(vm, L, { devTree: false, outDir }, lock, inventory, record.name);
  } catch (error) {
    inventory.error = String(error);
    L.log(`INVENTORY FAILED: ${inventory.error}`);
  } finally {
    await deleteVm(vm, vmId, `${record.name} (inventory)`, ledger);
  }
  inventory.inventoryMs = Date.now() - t0;
  // Re-read: the bake json is this run's image record and nothing else writes it while this runs.
  const latest = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  writeFileSync(file, `${JSON.stringify({ ...latest, ...inventory, inventorySteps: L.steps }, null, 2)}\n`);
  L.log(`INVENTORY_DONE ${record.name} ${((inventory.inventoryMs as number) / 1000).toFixed(1)}s components=${String(inventory.sbomComponents ?? "none")}`);
  return inventory.error ? 1 : 0;
}
