#!/usr/bin/env bun
/**
 * Retired raw classic-provider benchmark entrypoint.
 *
 * Keep the alias fail-fast so it cannot allocate a classic Freestyle VM.
 */
console.error("bench-raw-vm-create.ts is retired with classic Cloud; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exit(2);
