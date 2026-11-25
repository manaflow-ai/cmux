#!/usr/bin/env bun
// The root filesystem tarball for the qcow2 export (RFD 0100 step 6). Run from web/:
//   bun ../images/cmux-vm/qcow2-export.ts --snapshot <sh-id> --tag <tag> --out-dir <dir>
// Implementation: web/scripts/cmux-vm-image/qcow2-export.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/qcow2-export.ts");
process.exit(await main());
