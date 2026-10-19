import { directDevBackendOrigin } from "../../app/lib/direct-dev-backend-origin";
import {
  authorizationServerMetadata,
  exchangeToken,
  McpOauthError,
  oauthErrorResponse,
  oauthJsonResponse,
  protectedResourceMetadata,
  registerClient,
  revokeToken,
} from "./oauth";
import { mcpOauthDbStore } from "./oauthStore";

const HOST_PATTERN = /^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$/;

/**
 * The origin the client used. Vercel and Tailscale Serve both forward the real
 * host, so it comes from `x-forwarded-host`/`host` before the request URL, which
 * a development server reports as its bind address. That keeps one stack correct
 * when it is reached through more than one hostname (its tailnet URL and a
 * public tunnel): each client gets identifiers for the host it called.
 */
export function mcpPublicOrigin(request: Request, env: Record<string, string | undefined> = process.env): string {
  const host = (request.headers.get("x-forwarded-host") ?? request.headers.get("host"))?.split(",")[0]?.trim();
  if (host && HOST_PATTERN.test(host)) {
    const forwardedProto = request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim();
    const proto = forwardedProto === "http" || forwardedProto === "https"
      ? forwardedProto
      : new URL(request.url).protocol.replace(":", "");
    return `${proto}://${host}`;
  }
  return directDevBackendOrigin(env)?.origin ?? new URL(request.url).origin;
}

/**
 * The OAuth issuer, which also names the MCP resource. It is the public origin
 * unless `CMUX_MCP_OAUTH_ISSUER` sets one: a development stack reachable by MCP
 * hosts only through a public tunnel sets it to the tunnel's origin, while the
 * browser keeps signing in on the stack's own host.
 */
export function mcpIssuerFor(fallbackOrigin: string, env: Record<string, string | undefined> = process.env): string {
  const configured = env.CMUX_MCP_OAUTH_ISSUER?.trim().replace(/\/+$/, "");
  return configured && /^https:\/\/[^/?#]+$/.test(configured) ? configured : fallbackOrigin;
}

/** Header the dev tunnel proxy (`scripts/mcp-dev-tunnel.py`) sets to its public origin. */
export const MCP_DEV_TUNNEL_HEADER = "x-cmux-public-origin";
const DEV_TUNNEL_ORIGIN = /^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/;

/**
 * A public tunnel origin for a direct dev-backend stack, or undefined. The
 * dev-backend gateway routes by its own tailnet host and rewrites
 * `x-forwarded-host`, so a tunnel names itself in a separate value. Production
 * (no direct dev-backend origin) never accepts one.
 */
export function devTunnelOrigin(value: string | null | undefined, env: Record<string, string | undefined> = process.env): string | undefined {
  if (!directDevBackendOrigin(env)) return undefined;
  const origin = value?.trim().replace(/\/+$/, "");
  return origin && DEV_TUNNEL_ORIGIN.test(origin) ? origin : undefined;
}

/** The dev tunnel issuer a consent request's `resource` names, for the tailnet-host consent page. */
export function devTunnelIssuerForResource(resource: string | null, env: Record<string, string | undefined> = process.env): string | undefined {
  if (!resource) return undefined;
  try {
    return devTunnelOrigin(new URL(resource).origin, env);
  } catch {
    return undefined;
  }
}

export function mcpIssuer(request: Request, env: Record<string, string | undefined> = process.env): string {
  return devTunnelOrigin(request.headers.get(MCP_DEV_TUNNEL_HEADER), env)
    ?? mcpIssuerFor(mcpPublicOrigin(request, env), env);
}

// Metadata and the token endpoint are called by the MCP host's browser or
// server; CORS lets browser-based hosts (MCP Inspector) read them.
const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, mcp-protocol-version",
};

export function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
}

export function corsPreflight(): Response {
  return new Response(null, { status: 204, headers: CORS_HEADERS });
}

function metadataResponse(body: unknown): Response {
  return withCors(new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json", "cache-control": "public, max-age=300" },
  }));
}

export function authorizationServerMetadataResponse(request: Request): Response {
  return metadataResponse(authorizationServerMetadata(mcpIssuer(request), mcpPublicOrigin(request)));
}

export function protectedResourceMetadataResponse(request: Request): Response {
  return metadataResponse(protectedResourceMetadata(mcpIssuer(request)));
}

async function formFrom(request: Request): Promise<URLSearchParams> {
  const type = request.headers.get("content-type") ?? "";
  if (!type.includes("application/x-www-form-urlencoded")) {
    throw new McpOauthError("invalid_request", "Use application/x-www-form-urlencoded.");
  }
  const text = await request.text();
  if (text.length > 16 * 1024) throw new McpOauthError("invalid_request", "The request is too large.");
  return new URLSearchParams(text);
}

async function oauthRoute(operation: () => Promise<Response>): Promise<Response> {
  try {
    return withCors(await operation());
  } catch (error) {
    if (error instanceof McpOauthError) return withCors(oauthErrorResponse(error));
    console.error("MCP OAuth request failed", error);
    return withCors(oauthErrorResponse(new McpOauthError("server_error", "The request failed. Try again.", 500)));
  }
}

export function tokenRoute(request: Request): Promise<Response> {
  return oauthRoute(async () => {
    const form = await formFrom(request);
    return oauthJsonResponse(await exchangeToken(mcpOauthDbStore(), form, mcpIssuer(request)));
  });
}

export function registerRoute(request: Request): Promise<Response> {
  return oauthRoute(async () => {
    const text = await request.text();
    if (text.length > 16 * 1024) throw new McpOauthError("invalid_client_metadata", "The request is too large.");
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      throw new McpOauthError("invalid_client_metadata", "Expected a JSON body.");
    }
    return oauthJsonResponse(await registerClient(mcpOauthDbStore(), body), 201);
  });
}

export function revokeRoute(request: Request): Promise<Response> {
  return oauthRoute(async () => {
    await revokeToken(mcpOauthDbStore(), await formFrom(request));
    return new Response(null, { status: 200 });
  });
}
