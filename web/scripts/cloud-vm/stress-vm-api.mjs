#!/usr/bin/env node
/**
 * Retired classic Cloud stress entrypoint.
 *
 * The old alias fails before Stack/Auth or legacy API access. Use the NEXT Cloud
 * development E2E instead of creating classic throwaway machines.
 */
console.error("stress-vm-api.mjs is a retired internal classic Cloud tool; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exitCode = 2;
