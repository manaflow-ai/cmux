#!/usr/bin/env bun
// Bring a running Cloud machine onto the cmux guest kernel, keeping its disk. Run from web/:
//   bun ../images/cmux-vm/guest-kernel-install.ts --vm <vm-id> --bake-json <out-dir>/bake-<name>.json [--switch-now]
// Implementation: web/scripts/cmux-vm-image/guest-kernel-install.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/guest-kernel-install.ts");
process.exit(await main());
