import { connection } from "next/server";
import { schemaParityResponse } from "../../../../services/health/schemaParity";

/**
 * Public, unauthenticated drift check between the migrations bundled in the
 * deployed code and the migrations applied to the Cloud VM database. Web code
 * auto-deploys on merge while database migrations are applied through the
 * cloud-vm-migrate workflow, so the two can drift (Aug 24/25 2026: deployed
 * code queried columns whose migrations were merged but not applied, and
 * account deletion failed with VmDatabaseError until the migration ran).
 *
 * 200 {"status":"ok"|"ahead",...} when the database is not lagging the code;
 * 503 {"status":"behind","pending":[...]} when applied migrations lag;
 * 503 {"status":"unavailable"} when the database cannot be queried. The body
 * only ever contains migration names, never connection or error details.
 */
export async function GET(): Promise<Response> {
  // Cache Components is enabled, so a GET handler can be prerendered at build
  // time (`export const dynamic` no longer exists). Parity must be measured
  // per request, never baked into the build.
  await connection();
  return schemaParityResponse();
}
