export const CANARY_PATH = "/v1/manaflow-ai/cmux/artifacts/10610975375/08f56e901618eff4aacdffbd3046d9e9732b638004cba1d69ad44f447199608f.zip";

export function canaryAllowed(request: Request, enabled: string | undefined, expiresAt: string | undefined, accessToken: string | undefined, now = Date.now()): boolean {
  const url = new URL(request.url);
  const expiry = Date.parse(expiresAt ?? "");
  return typeof accessToken === "string" && /^[a-f0-9]{64}$/.test(accessToken)
    && request.headers.get("X-Cmux-Canary-Token") === accessToken && Number.isFinite(expiry) && now < expiry
    && expiry <= Date.parse("2026-09-23T18:16:23Z") && enabled === "true" && request.method === "GET" && url.pathname === CANARY_PATH && !url.search;
}
