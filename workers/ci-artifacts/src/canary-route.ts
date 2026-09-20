export const CANARY_PATH = "/v1/manaflow-ai/cmux/artifacts/10610975375/08f56e901618eff4aacdffbd3046d9e9732b638004cba1d69ad44f447199608f.zip";
export const READINESS_PATH = "/__cmux_artifact_canary_ready";

export type CanaryConfiguration = {
  CANARY_ENABLED?: string;
  CANARY_EXPIRES_AT?: string;
  CANARY_ACCESS_TOKEN?: string;
};

function authorized(request: Request, enabled: string | undefined, expiresAt: string | undefined, accessToken: string | undefined, now: number): boolean {
  const expiry = Date.parse(expiresAt ?? "");
  return typeof accessToken === "string" && /^[a-f0-9]{64}$/.test(accessToken)
    && request.headers.get("X-Cmux-Canary-Token") === accessToken && Number.isFinite(expiry) && now < expiry
    && expiry <= Date.parse("2026-09-23T18:16:23Z") && enabled === "true" && request.method === "GET" && !new URL(request.url).search;
}

export function canaryAllowed(request: Request, enabled: string | undefined, expiresAt: string | undefined, accessToken: string | undefined, now = Date.now()): boolean {
  return new URL(request.url).pathname === CANARY_PATH && authorized(request, enabled, expiresAt, accessToken, now);
}

export async function handleCanaryRequest(request: Request, configuration: CanaryConfiguration, forward: () => Promise<Response>, now = Date.now()): Promise<Response> {
  const path = new URL(request.url).pathname;
  const accepted = path === READINESS_PATH
    ? authorized(request, configuration.CANARY_ENABLED, configuration.CANARY_EXPIRES_AT, configuration.CANARY_ACCESS_TOKEN, now)
    : canaryAllowed(request, configuration.CANARY_ENABLED, configuration.CANARY_EXPIRES_AT, configuration.CANARY_ACCESS_TOKEN, now);
  if (!accepted) {
    return new Response("Not found", { status: 404, headers: {
      "Cache-Control": "no-store", "X-Cmux-Canary-Stage": "gate-rejected",
    } });
  }
  if (path === READINESS_PATH) {
    // No broker/DO invocation, GitHub lookup, R2 request or artifact import.
    return new Response(null, { status: 204, headers: {
      "Cache-Control": "no-store", "X-Cmux-Canary-Stage": "ready-v1",
    } });
  }
  const response = await forward();
  const marked = new Response(response.body, response);
  marked.headers.set("X-Cmux-Canary-Stage", "artifact-v1");
  return marked;
}
