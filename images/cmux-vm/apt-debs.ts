#!/usr/bin/env bun
// Record every Ubuntu pin's .deb (pool path, sha256, size) from the lock's dated snapshot. Run from web/:
//   bun ../images/cmux-vm/apt-debs.ts [--lock <path>] [--check]
// Implementation: web/scripts/cmux-vm-image/apt-debs.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/apt-debs.ts");
process.exit(await main());
