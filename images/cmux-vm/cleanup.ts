#!/usr/bin/env bun
// Delete every VM and snapshot a bake/smoke/repro run recorded in its ledger and has not deleted. Run from web/:
//   bun ../images/cmux-vm/cleanup.ts --ledger <out-dir>/resources.tsv
// Implementation: web/scripts/cmux-vm-image/cleanup.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/cleanup.ts");
process.exit(await main());
