#!/usr/bin/env bun
// Bake the cmux VM image from inputs.lock.json. Run from web/ (it imports the Freestyle SDK):
//   bun ../images/cmux-vm/bake.ts --tag <tag> [--out-dir <dir>] [--update-lock]
// Implementation: web/scripts/cmux-vm-image/bake.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/bake.ts");
process.exit(await main());
