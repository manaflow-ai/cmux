import { authorizeCronRequest } from "../../../../services/cronAuth";
import { processRunQueue } from "../../../../services/runs/runner";
export const maxDuration = 960;
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) return Response.json({ error: "unauthorized" }, { status: 401 });
  try { return Response.json(await processRunQueue()); }
  catch { return Response.json({ error: "run_worker_unavailable" }, { status: 503 }); }
}
