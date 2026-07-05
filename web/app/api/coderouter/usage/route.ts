import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  publicUsageSummary,
  runCoderouterWorkflow,
  usageSummary,
} from "../../../../services/coderouter/workflows";
import { authenticateCoderouter, coderouterErrorResponse } from "../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const rawDays = new URL(request.url).searchParams.get("days");
  const days = rawDays && /^\d+$/.test(rawDays) ? Math.min(Math.max(Number(rawDays), 1), 90) : 30;
  try {
    const summary = await runCoderouterWorkflow(usageSummary({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      days,
    }));
    return jsonResponse({
      days,
      balanceMicros: summary.balanceMicros,
      totals: publicUsageSummary(summary.rows),
    });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
