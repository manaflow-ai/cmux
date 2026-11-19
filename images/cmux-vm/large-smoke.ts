#!/usr/bin/env bun
// Smoke-test the large cmux VM image (bake.ts --large): clones boot at the default Cloud chat start size with no resize. Run from web/:
//   bun ../images/cmux-vm/large-smoke.ts --snapshot <sh-id> --tag <tag> [--clones 2] [--out-dir <dir>]
// Implementation: web/scripts/cmux-vm-image/large-smoke.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/large-smoke.ts");
process.exit(await main());
