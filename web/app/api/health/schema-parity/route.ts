import {
  listBundledMigrations,
  schemaParityReport,
  type SchemaParityReport,
} from "../../../../services/health/schemaParity";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

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
 * 503 {"status":"unavailable"} when the database cannot be queried (codeHead
 * is still reported when the bundled migrations are readable, so deployments
 * without a database, e.g. previews, still prove the route and file tracing
 * work). The body only ever contains migration names, never connection or
 * error details.
 */
export async function GET(): Promise<Response> {
  let report: SchemaParityReport;
  try {
    report = await schemaParityReport();
  } catch (error) {
    console.error("schema-parity health check failed", error);
    let codeHead: string | null = null;
    try {
      codeHead = listBundledMigrations().at(-1) ?? null;
    } catch {
      // The migrations folder is missing from the serverless bundle.
    }
    return jsonResponse({ status: "unavailable", codeHead }, 503);
  }
  return jsonResponse(report, report.status === "behind" ? 503 : 200);
}
