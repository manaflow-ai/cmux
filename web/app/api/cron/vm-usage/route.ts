import { reportVmUsageForActiveSubscriptions } from "../../../../services/billing/vmUsageReporting";
import { captureCoderouterError } from "../../../../services/errors";

export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    const result = await reportVmUsageForActiveSubscriptions();
    return Response.json({ ok: result.failed === 0, ...result }, {
      status: result.failed === 0 ? 200 : 503,
    });
  } catch (error) {
    captureCoderouterError(error, {
      operation: "vm_usage_reporting_cron",
      recoverable: true,
    });
    return Response.json(
      {
        error: "vm_usage_reporting_failed",
        message: "VM usage reporting failed; retry the cron run.",
        retryable: true,
      },
      {
        status: 503,
        headers: { "Retry-After": "60" },
      },
    );
  }
}
