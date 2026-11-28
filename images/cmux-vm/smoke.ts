#!/usr/bin/env bun
// Smoke-test a cmux VM image snapshot on fresh clones. Run from web/:
//   bun ../images/cmux-vm/smoke.ts --snapshot <sh-id> --tag <tag> [--clones 5] [--out-dir <dir>]
// Implementation: web/scripts/cmux-vm-image/smoke.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/smoke.ts");
process.exit(await main());
