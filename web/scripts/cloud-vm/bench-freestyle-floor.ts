#!/usr/bin/env bun
/**
 * Retired classic-provider benchmark entrypoint.
 *
 * Keep this filename as a fail-fast alias so old operator commands cannot
 * allocate a classic Freestyle VM by accident.
 */
console.error("bench-freestyle-floor.ts is retired with classic Cloud; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exit(2);
