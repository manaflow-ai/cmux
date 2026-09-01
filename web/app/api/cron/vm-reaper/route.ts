import { captureVmReaperSummary } from "../../../../services/vms/observability";
import { reapVmResources } from "../../../../services/vms/reaper";
import { runVmWorkflow } from "../../../../services/vms/workflows";

// Bounded batches keep a run well under this budget; the cap only guards a
// hung provider call.
export const maxDuration = 300;

export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    const summary = await runVmWorkflow(reapVmResources());
    // Best effort and bounded; never turns a successful run into a 500.
    await captureVmReaperSummary(summary);
    return Response.json({ ok: true, ...summary });
  } catch (err) {
    console.error("[VM] cron reaper failed", err);
    return Response.json({ error: "vm_reaper_failed" }, { status: 500 });
  }
}
