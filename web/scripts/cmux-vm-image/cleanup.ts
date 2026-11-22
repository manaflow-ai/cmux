/**
 * Delete what one image run created: every id its ledger (resources.tsv)
 * records as created and not yet deleted. Never lists or deletes anything
 * else on the account.
 *
 * Usage (from web/): bun ../images/cmux-vm/cleanup.ts --ledger <out-dir>/resources.tsv [--keep-snapshot]
 *
 * --keep-snapshot: the run's snapshot is recorded as kept (a dev channel candidate) and only
 * its VMs (builder, smoke clones) are deleted. Prints KEPT_SNAPSHOT <id> <name>.
 */
import path from "node:path";
import { argValue, freestyleClient, Ledger } from "./guest";

export async function main(argv = process.argv): Promise<number> {
  const file = argValue("--ledger", argv);
  if (!file) throw new Error("usage: cleanup.ts --ledger <resources.tsv>");
  const ledger = new Ledger(path.resolve(file));
  if (argv.includes("--keep-snapshot")) {
    for (const row of ledger.live().filter((r) => r.kind === "snapshot")) {
      ledger.record(row.id, row.kind, row.name, "kept");
      console.log(`KEPT_SNAPSHOT ${row.id} ${row.name}`);
    }
  }
  const live = ledger.live();
  if (live.length === 0) {
    console.log("nothing to delete");
    return 0;
  }
  const fs = freestyleClient();
  let failed = 0;
  // VMs first: a snapshot may still back a running clone.
  for (const row of [...live].sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "vm" ? -1 : 1))) {
    try {
      if (row.kind === "vm") await fs.vms.delete(row.id);
      else await fs.vms.snapshots.delete(row.id);
      ledger.record(row.id, row.kind, row.name, "deleted");
      console.log(`deleted ${row.kind} ${row.id} (${row.name})`);
    } catch (error) {
      const message = String(error);
      if (/not.?found|404/i.test(message)) {
        ledger.record(row.id, row.kind, row.name, "deleted");
        console.log(`already gone ${row.kind} ${row.id}`);
      } else {
        failed++;
        console.error(`could not delete ${row.kind} ${row.id}: ${message.slice(0, 200)}`);
      }
    }
  }
  return failed === 0 ? 0 : 1;
}
