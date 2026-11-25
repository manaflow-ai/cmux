import { authorizeCronRequest } from "../../../../services/cronAuth";
import { isCloudIntroEnabled } from "../../../../services/billing/cloudIntro";
import { runCloudIntroRenewals } from "../../../../services/billing/cloudIntroRenewal";
import { runCloudIntroStatements } from "../../../../services/billing/cloudIntroStatementJob";
import { captureCoderouterError } from "../../../../services/errors";

export const maxDuration = 60;

/**
 * The cmux Cloud pass's daily steps (RFD 0052), a no-op with the pass flag off:
 * first the day-30 Plus charge for renew buyers (only with
 * CMUX_CLOUD_INTRO_RENEW_CHARGE=1), then the statements due on days 21, 27
 * and 30, so a day-30 statement says how the charge went.
 */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  if (!isCloudIntroEnabled()) {
    return Response.json({ ok: true, skipped: true, considered: 0, sent: 0, noEmail: 0, failed: 0 });
  }

  try {
    const { defaultCloudIntroRenewalDependencies, defaultCloudIntroStatementDependencies } = await import(
      "../../../../services/billing/cloudIntroStatementDefaults"
    );
    const now = new Date();
    const renewals = await runCloudIntroRenewals(defaultCloudIntroRenewalDependencies(now));
    const result = await runCloudIntroStatements(defaultCloudIntroStatementDependencies(now));
    // A charge whose outcome is unknown holds that pass's day-30 statement; 503 makes it visible.
    const ok = result.failed === 0 && renewals.unknown === 0;
    return Response.json({ ok, ...result, renewals }, { status: ok ? 200 : 503 });
  } catch (error) {
    captureCoderouterError(error, { operation: "cloud_pass_statements_cron", recoverable: true });
    return Response.json(
      { error: "cloud_pass_statements_failed", message: "cmux Cloud pass statements failed; retry the cron run.", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
