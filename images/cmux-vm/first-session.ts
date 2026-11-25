#!/usr/bin/env bun
// Measure a first session's package installs on an image, cold and with prewarmed package caches. Run from web/:
//   bun ../images/cmux-vm/first-session.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]
// Implementation: web/scripts/cmux-vm-image/first-session.ts.
const { main } = await import("../../web/scripts/cmux-vm-image/first-session.ts");
process.exit(await main());
