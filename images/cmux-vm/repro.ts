#!/usr/bin/env bun
// Bake twice from inputs.lock.json and diff SBOM name+version and file hashes. Run from web/:
//   bun ../images/cmux-vm/repro.ts --tag <tag> [--out-dir <dir>]
// Implementation: web/scripts/cmux-vm-image/repro.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/repro.ts");
process.exit(await main());
