import { timingSafeEqual } from "node:crypto";
import { jsonResponse } from "@/services/vms/routeHelpers";
import { revokeExpiredIdentityLeases, runVmWorkflow } from "@/services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) {
    console.error("vm.leases.revoke_expired.cron_secret_missing");
    return jsonResponse({ error: "service_unavailable" }, 503);
  }

  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const token = authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice("bearer ".length).trim()
    : "";
  const tokenBuffer = Buffer.from(token);
  const secretBuffer = Buffer.from(secret);
  const tokenMatches =
    tokenBuffer.length === secretBuffer.length &&
    timingSafeEqual(tokenBuffer, secretBuffer);
  if (!tokenMatches) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const revoked = await runVmWorkflow(revokeExpiredIdentityLeases());
  return jsonResponse({ ok: true, revoked });
}
