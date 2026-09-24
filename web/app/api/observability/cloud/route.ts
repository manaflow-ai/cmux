import { after } from "next/server";
import { checkRateLimit } from "@vercel/firewall";
import { verifyRequest } from "../../../../services/vms/auth";
import { makeCloudTelemetryHandler } from "../../../../services/observability/cloudTelemetryIngest";
import { acceptCloudTelemetry } from "../../../../services/observability/cloudTelemetryRepository";
import { drainCloudDiagnostics } from "../../../../services/observability/cloudTelemetryDelivery";
import { reportMissingRateLimitRule } from "../../../../services/rateLimitObservability";

export const POST = makeCloudTelemetryHandler({
  authenticate: (request) => verifyRequest(request, { allowCookie: false }),
  checkIngress: async (request) => {
    if (process.env.VERCEL !== "1") return true;
    const rule = process.env.CMUX_CLOUD_DIAGNOSTICS_RATE_LIMIT_ID?.trim();
    if (!rule) {
      reportMissingRateLimitRule({ route: "/api/observability/cloud", reason: "unset" });
      throw new Error("diagnostics_rate_limit_unconfigured");
    }
    const result = await checkRateLimit(rule, { request });
    if (result.rateLimited || result.error === "blocked") return false;
    if (result.error) throw new Error("diagnostics_rate_limit_unavailable");
    return true;
  },
  accept: acceptCloudTelemetry,
  scheduleDrain: () => after(async () => { await drainCloudDiagnostics(); }),
  now: Date.now,
});
