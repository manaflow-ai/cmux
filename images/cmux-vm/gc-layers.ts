#!/usr/bin/env bun
// Delete cached layer snapshots no image needs (keeps the newest per layer, every referenced one and their parents).
// Run from web/: bun ../images/cmux-vm/gc-layers.ts [--keep 3] [--recent-hours 6] [--dry-run]
// Implementation: web/scripts/cmux-vm-image/gc-layers.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/gc-layers.ts");
process.exit(await main());
