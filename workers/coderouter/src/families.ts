import type { CredentialClass, EndpointClass, Family } from "./types";

export const MAX_BUFFERED_BODY_BYTES = 20 * 1024 * 1024;

export interface RouteMatch {
  family: Family;
  endpointClass: EndpointClass;
  upstreamBase: string;
  upstreamPath: string;
}

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

export function matchRoute(url: URL): RouteMatch | null {
  if (url.pathname.startsWith("/anthropic/") || url.pathname === "/anthropic") {
    return {
      family: "anthropic",
      endpointClass: "anthropic",
      upstreamBase: "https://api.anthropic.com",
      upstreamPath: stripPrefix(url.pathname, "/anthropic") || "/",
    };
  }
  if (url.pathname.startsWith("/openai/v1/") || url.pathname === "/openai/v1") {
    return {
      family: "openai",
      endpointClass: "openai_api",
      upstreamBase: "https://api.openai.com",
      upstreamPath: `/v1${stripPrefix(url.pathname, "/openai/v1") || ""}`,
    };
  }
  if (url.pathname.startsWith("/codex/") || url.pathname === "/codex") {
    return {
      family: "openai",
      endpointClass: "codex",
      upstreamBase: "https://chatgpt.com",
      upstreamPath: `/backend-api/codex${stripPrefix(url.pathname, "/codex") || ""}`,
    };
  }
  return null;
}

function stripPrefix(pathname: string, prefix: string): string {
  const stripped = pathname.slice(prefix.length);
  return stripped.startsWith("/") ? stripped : `/${stripped}`;
}

export function buildUpstreamUrl(route: RouteMatch, inputUrl: URL): string {
  const url = new URL(route.upstreamBase);
  url.pathname = route.upstreamPath;
  url.search = inputUrl.search;
  return url.toString();
}

export function sanitizeRequestHeaders(headers: Headers): Headers {
  const sanitized = new Headers();
  for (const [name, value] of headers) {
    const lower = name.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(lower)) continue;
    if (lower === "host" || lower === "authorization" || lower === "x-api-key") continue;
    if (lower === "chatgpt-account-id") continue;
    if (lower.startsWith("x-coderouter-")) continue;
    sanitized.set(name, value);
  }
  return sanitized;
}

export function sanitizeResponseHeaders(headers: Headers): Headers {
  const sanitized = new Headers();
  for (const [name, value] of headers) {
    const lower = name.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(lower)) continue;
    sanitized.set(name, value);
  }
  return sanitized;
}

export function injectCredentialHeaders(
  endpointClass: EndpointClass,
  credentialClass: CredentialClass,
  headers: Headers,
  authHeaders: Record<string, string>,
): Headers {
  const next = sanitizeRequestHeaders(headers);
  if (endpointClass === "anthropic") {
    if (credentialClass === "oauth") {
      next.set("authorization", authHeaders.authorization ?? authHeaders.Authorization ?? "");
      mergeAnthropicBeta(next, "oauth-2025-04-20");
    } else {
      next.set("x-api-key", authHeaders["x-api-key"] ?? authHeaders["X-Api-Key"] ?? "");
      removeAnthropicBeta(next, "oauth-2025-04-20");
      next.delete("authorization");
    }
    return next;
  }
  if (endpointClass === "openai_api") {
    next.set("authorization", authHeaders.authorization ?? authHeaders.Authorization ?? "");
    return next;
  }
  next.set("authorization", authHeaders.authorization ?? authHeaders.Authorization ?? "");
  const accountId = authHeaders["chatgpt-account-id"] ?? authHeaders["ChatGPT-Account-ID"];
  if (accountId) next.set("ChatGPT-Account-ID", accountId);
  return next;
}

export function mergeAnthropicBeta(headers: Headers, value: string): void {
  const parts = parseCommaHeader(headers.get("anthropic-beta"));
  if (!parts.includes(value)) parts.push(value);
  if (parts.length > 0) headers.set("anthropic-beta", parts.join(","));
}

export function removeAnthropicBeta(headers: Headers, value: string): void {
  const parts = parseCommaHeader(headers.get("anthropic-beta")).filter((part) => part !== value);
  if (parts.length > 0) headers.set("anthropic-beta", parts.join(","));
  else headers.delete("anthropic-beta");
}

function parseCommaHeader(value: string | null): string[] {
  if (!value) return [];
  const seen = new Set<string>();
  const parts: string[] = [];
  for (const raw of value.split(",")) {
    const part = raw.trim();
    if (!part || seen.has(part)) continue;
    seen.add(part);
    parts.push(part);
  }
  return parts;
}

export function isUsageLimitResponse(
  endpointClass: EndpointClass,
  credentialClass: CredentialClass,
  status: number,
  contentType: string | null,
  bodyText: string | null,
): boolean {
  if (status === 429) return true;
  if (endpointClass === "anthropic" && credentialClass === "oauth" && status === 401) return true;
  if (endpointClass !== "codex" || status < 400 || !contentType?.toLowerCase().includes("json") || !bodyText) {
    return false;
  }
  try {
    const parsed = JSON.parse(bodyText) as { error?: { type?: unknown; code?: unknown; message?: unknown } };
    const error = parsed.error ?? {};
    const typeOrCode = [error.type, error.code].filter((value): value is string => typeof value === "string");
    if (typeOrCode.some((value) => value === "usage_limit_reached" || value === "rate_limit_exceeded")) return true;
    return typeof error.message === "string" && error.message.toLowerCase().includes("usage limit");
  } catch {
    return false;
  }
}

export function allowedClassesForEndpoint(endpointClass: EndpointClass): CredentialClass[] {
  if (endpointClass === "codex") return ["oauth"];
  if (endpointClass === "openai_api") return ["byok", "managed"];
  return ["oauth", "byok", "managed"];
}
