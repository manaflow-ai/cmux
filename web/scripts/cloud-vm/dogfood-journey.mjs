#!/usr/bin/env node
/**
 * Retired classic Cloud dogfood entrypoint.
 *
 * Keep the package alias fail-fast so an old workflow cannot create classic
 * customer-style machines. NEXT Cloud development coverage lives in dev-e2e.ts.
 */
console.error("dogfood-journey.mjs is a retired internal classic Cloud tool; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exitCode = 2;
