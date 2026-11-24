#!/usr/bin/env node
/**
 * Retired classic Cloud benchmark entrypoint.
 *
 * NEXT Cloud's development API is exercised by dev-e2e.ts; this legacy alias
 * must fail before importing the classic SDK or making a network request.
 */
console.error("bench-vm-startup.mjs is a retired internal classic Cloud tool; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exitCode = 2;
