#!/usr/bin/env bun
// The SBOM and file manifest of a layered bake, after its snapshot (bake.ts --defer-inventory). Run from web/:
//   bun ../images/cmux-vm/inventory.ts --out-dir <dir>
// Implementation: web/scripts/cmux-vm-image/inventory.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/inventory.ts");
process.exit(await main());
