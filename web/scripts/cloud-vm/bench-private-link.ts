#!/usr/bin/env bun
/**
 * Retired classic-provider transport benchmark entrypoint.
 *
 * The alias intentionally fails before loading the classic Freestyle driver or
 * opening a tunnel. NEXT Cloud transport coverage lives in dev-e2e.ts.
 */
console.error("bench-private-link.ts is retired with classic Cloud; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exit(2);
