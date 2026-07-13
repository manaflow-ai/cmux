import { createHash } from "node:crypto";

export type IrohFirewallCheckResult = {
  readonly rateLimited: boolean;
  readonly error?: "not-found" | "blocked";
};

export type IrohFirewallCheck = (
  rateLimitId: string,
  options: {
    readonly request: Request;
    readonly rateLimitKey: string;
    readonly signal: AbortSignal;
  },
) => Promise<IrohFirewallCheckResult>;

type IrohFirewallEnvironment = Readonly<{
  readonly VERCEL_URL?: string;
  readonly VERCEL_PROJECT_PRODUCTION_URL?: string;
  readonly PUBLIC_VERCEL_FIREWALL_PATH_PREFIX?: string;
  readonly NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX?: string;
  readonly VERCEL_AUTOMATION_BYPASS_SECRET?: string;
  readonly RATE_LIMIT_SECRET?: string;
}>;

type IrohFirewallDependencies = Readonly<{
  readonly environment?: IrohFirewallEnvironment;
  readonly fetch?: typeof globalThis.fetch;
}>;

// @vercel/firewall 1.2.1 does not pass an AbortSignal to its internal fetch.
// Keep the documented programmatic endpoint behavior while making cancellation
// part of this boundary's contract so a stalled check cannot outlive its slot.
export function createIrohVercelFirewallCheck(
  dependencies: IrohFirewallDependencies = {},
): IrohFirewallCheck {
  const environment: IrohFirewallEnvironment = dependencies.environment ?? {
    VERCEL_URL: process.env.VERCEL_URL,
    VERCEL_PROJECT_PRODUCTION_URL: process.env.VERCEL_PROJECT_PRODUCTION_URL,
    PUBLIC_VERCEL_FIREWALL_PATH_PREFIX: process.env.PUBLIC_VERCEL_FIREWALL_PATH_PREFIX,
    NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX: process.env.NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX,
    VERCEL_AUTOMATION_BYPASS_SECRET: process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
    RATE_LIMIT_SECRET: process.env.RATE_LIMIT_SECRET,
  };
  const fetcher = dependencies.fetch ?? globalThis.fetch;
  return async (rateLimitId, { request, rateLimitKey, signal }) => {
    const host = trustedFirewallHost(request, environment);
    const pathPrefix = normalizedPathPrefix(
      environment.PUBLIC_VERCEL_FIREWALL_PATH_PREFIX
        ?? environment.NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX,
    );
    const url = `https://${host}${pathPrefix}/.well-known/vercel/rate-limit-api/${encodeURIComponent(rateLimitId)}`;
    const secretSuffix = `${environment.VERCEL_AUTOMATION_BYPASS_SECRET ?? ""}${environment.RATE_LIMIT_SECRET ?? ""}`;
    const keyDigest = createHash("sha256")
      .update(`${rateLimitKey}${rateLimitId}${secretSuffix}`)
      .digest("hex");
    const headers = new Headers({
      "user-agent": "Bot/Vercel Rate Limit Checker",
      "x-vercel-rate-limit-api": rateLimitId,
      "x-vercel-rate-limit-key": `${rateLimitKey}-${keyDigest}`,
      "x-forwarded-for": request.headers.get("x-forwarded-for") ?? "",
      "x-real-ip": request.headers.get("x-real-ip") ?? "",
      "x-vercel-protection-bypass": environment.VERCEL_AUTOMATION_BYPASS_SECRET ?? "",
    });
    const previewJwt = cookieValue(request.headers.get("cookie"), "_vercel_jwt");
    if (previewJwt) headers.set("cookie", `_vercel_jwt=${previewJwt}`);
    for (const [name, value] of request.headers.entries()) {
      headers.append(`x-rr-${name}`, value);
    }

    const response = await fetcher(url, {
      method: "GET",
      headers,
      redirect: "manual",
      signal,
    });
    await response.body?.cancel().catch(() => {});
    switch (response.status) {
      case 204: return { rateLimited: false };
      case 429: return { rateLimited: true };
      case 403: return { rateLimited: true, error: "blocked" };
      case 404: return { rateLimited: false, error: "not-found" };
      default: throw new Error("unexpected_firewall_status");
    }
  };
}

export const checkIrohVercelFirewall = createIrohVercelFirewallCheck();

function trustedFirewallHost(request: Request, environment: IrohFirewallEnvironment): string {
  const deploymentHost = normalizedHost(environment.VERCEL_URL);
  const productionHost = normalizedHost(environment.VERCEL_PROJECT_PRODUCTION_URL);
  if (!deploymentHost && !productionHost) throw new Error("firewall_host_unavailable");

  const requestedHost = normalizedHost(request.headers.get("host") ?? new URL(request.url).host);
  if (requestedHost && (requestedHost === deploymentHost || requestedHost === productionHost)) {
    return requestedHost;
  }
  // A deployment URL can be protected by Vercel Authentication even when the
  // public project URL is intentionally reachable. Both values come from
  // Vercel, so prefer the stable project URL when the inbound host is not one
  // of the trusted values instead of making the rate-limit check hit SSO.
  return productionHost ?? deploymentHost!;
}

function normalizedHost(value: string | null | undefined): string | undefined {
  const candidate = value?.trim().toLowerCase();
  if (!candidate) return undefined;
  if (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?::[1-9][0-9]{0,4})?$/.test(candidate)) {
    throw new Error("invalid_firewall_host");
  }
  return candidate;
}

function normalizedPathPrefix(value: string | undefined): string {
  const candidate = value?.trim();
  if (!candidate) return "";
  const prefixed = candidate.startsWith("/") ? candidate : `/${candidate}`;
  if (!/^\/[A-Za-z0-9/_-]*$/.test(prefixed)) throw new Error("invalid_firewall_path_prefix");
  return prefixed.replace(/\/$/, "");
}

function cookieValue(header: string | null, name: string): string | undefined {
  for (const item of header?.split(";") ?? []) {
    const separator = item.indexOf("=");
    if (separator < 0 || item.slice(0, separator).trim() !== name) continue;
    const value = item.slice(separator + 1).trim();
    return value || undefined;
  }
  return undefined;
}
