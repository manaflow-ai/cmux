import { addAccount, parseCredential } from "../../../../services/coderouter/accounts";
import {
  resolveCoderouterUsageTeam,
  resolveCodeRouterRequestContext,
} from "../../../../services/coderouter/requestContext";
import { accountsWithUsage } from "../../../../services/coderouter/usage";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 128 * 1_024;

export async function GET(request: Request): Promise<Response> {
  const startedAt = performance.now();
  const authStartedAt = performance.now();
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;
  const authMs = performance.now() - authStartedAt;
  const result = await accountsWithUsage(resolved.teamId);
  const serializeStartedAt = performance.now();
  const body = JSON.stringify({
    teamId: resolved.teamId,
    accounts: result.accounts,
    usageAsOf: result.usageAsOf,
    usageAgeSeconds: Math.max(
      0,
      Math.floor((Date.now() - result.usageGeneratedAtMs) / 1_000),
    ),
    cacheMaxAgeSeconds: result.cacheMaxAgeSeconds,
  });
  const serializeMs = performance.now() - serializeStartedAt;
  const serverTiming = [
    timing("auth", authMs),
    timing("rds", result.timing.rdsMs),
    timing("provider", result.timing.providerMs),
    timing("serialize", serializeMs),
    timing("total", performance.now() - startedAt),
  ].join(", ");
  return new Response(body, {
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
      "server-timing": serverTiming,
      // Vercel may reserve/strip Server-Timing at the edge. Keep the same
      // standards-formatted value observable under a product header.
      "x-coderouter-server-timing": serverTiming,
    },
  });
}

export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "manage");
  if (!resolved.ok) return resolved.response;
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const credential = parseCredential(value);
  if (!credential) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const result = await addAccount(resolved.value.team.teamId, credential);
  return Response.json(result, {
    status: result.alreadyExists ? 200 : 201,
    headers: { "cache-control": "no-store" },
  });
}

function timing(name: string, duration: number): string {
  return `${name};dur=${Math.max(0, duration).toFixed(1)}`;
}
