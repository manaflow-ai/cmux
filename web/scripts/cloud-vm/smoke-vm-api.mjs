#!/usr/bin/env node
/**
 * Retired classic Cloud smoke entrypoint.
 *
 * Keep the package alias fail-fast so an old internal command cannot create,
 * inspect or sweep classic machines. NEXT Cloud development coverage is below.
 */
console.error("smoke-vm-api.mjs is a retired internal classic Cloud tool; it makes no network requests.");
console.error("On feat-cmux-next, use bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir> for NEXT Cloud development E2E.");
process.exitCode = 2;
