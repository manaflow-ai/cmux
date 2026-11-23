import { authorizeCronRequest } from "../../../../services/cronAuth";
import { isCloudIntroEnabled } from "../../../../services/billing/cloudIntro";
import { runCloudIntroStatements } from "../../../../services/billing/cloudIntroStatementJob";
import { captureCoderouterError } from "../../../../services/errors";

export const maxDuration = 60;

/** Sends the cmux Cloud pass statements due on days 21, 27 and 30 (RFD 0052); a no-op with the pass flag off. */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  if (!isCloudIntroEnabled()) {
    return Response.json({ ok: true, skipped: true, considered: 0, sent: 0, noEmail: 0, failed: 0 });
  }

  try {
    const { defaultCloudIntroStatementDependencies } = await import(
      "../../../../services/billing/cloudIntroStatementDefaults"
    );
    const result = await runCloudIntroStatements(defaultCloudIntroStatementDependencies());
    return Response.json({ ok: result.failed === 0, ...result }, { status: result.failed === 0 ? 200 : 503 });
  } catch (error) {
    captureCoderouterError(error, { operation: "cloud_pass_statements_cron", recoverable: true });
    return Response.json(
      { error: "cloud_pass_statements_failed", message: "cmux Cloud pass statements failed; retry the cron run.", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
