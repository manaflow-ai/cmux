import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { runReconcileExpiredLeases } from "../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET;
  const auth = request.headers.get("authorization");
  if (!secret || auth !== `Bearer ${secret}`) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const summary = await runReconcileExpiredLeases();
  return jsonResponse(summary);
}
