#!/usr/bin/env bun
// Time to first build on new machines of an image, before or after the dev tree. Run from web/:
//   bun ../images/cmux-vm/first-build.ts --mode before|after --snapshot <sh-id> --tag <tag> [--runs 3] [--out-dir <dir>]
//   bun ../images/cmux-vm/first-build.ts --report <before.json> <after.json>
// Implementation: web/scripts/cmux-vm-image/first-build.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/first-build.ts");
process.exit(await main());
