import {
  authenticateRouteToken,
  markAccountCooldown,
  selectAccountForRequest,
} from "./repository";
import { freshCredential } from "./refresh";

const CODEX_UPSTREAM = "https://chatgpt.com/backend-api/codex/responses";
const ALLOWED_REQUEST_HEADERS = [
  "accept",
  "content-type",
  "openai-beta",
  "openai-organization",
  "session_id",
  "user-agent",
] as const;

export async function proxyCodexRequest(request: Request): Promise<Response> {
  const token = bearerToken(request);
  if (!token) return jsonError("unauthorized", 401);
  const identity = await authenticateRouteToken(token);
  if (!identity) return jsonError("unauthorized", 401);

  const forwardedHeaders = new Headers();
  for (const name of ALLOWED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) forwardedHeaders.set(name, value);
  }
  const attempted: string[] = [];
  let upstream: Response | null = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await selectAccountForRequest(
      identity.teamId,
      "codex",
      attempted,
    );
    if (!account) break;
    attempted.push(account.id);
    let credential;
    try {
      credential = await freshCredential({
        teamId: identity.teamId,
        accountId: account.id,
        expectedRevision: account.vaultRevision,
      });
    } catch (error) {
      if (error && typeof error === "object" && "_tag" in error) {
        const tag = (error as { _tag: string })._tag;
        if (tag === "CodeRouterRefreshBusy") continue;
        if (tag === "CodeRouterCredentialBroken") continue;
      }
      throw error;
    }
    if (credential.provider !== "codex") continue;
    upstream = await sendCodex(request.clone(), forwardedHeaders, credential);
    if (upstream.status === 401) {
      try {
        const refreshed = await freshCredential({
          teamId: identity.teamId,
          accountId: account.id,
          expectedRevision: account.vaultRevision,
          force: true,
        });
        if (refreshed.provider === "codex") {
          upstream = await sendCodex(request.clone(), forwardedHeaders, refreshed);
        }
      } catch {
        continue;
      }
    }
    if (upstream.status === 429) {
      await markAccountCooldown(account.id, rateLimitDelay(upstream.headers));
      continue;
    }
    break;
  }
  if (!upstream) return jsonError("no_usable_account", 503);
  const responseHeaders = new Headers();
  for (const name of [
    "content-type",
    "openai-processing-ms",
    "x-request-id",
    "x-ratelimit-limit-requests",
    "x-ratelimit-remaining-requests",
    "x-ratelimit-reset-requests",
  ]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }
  responseHeaders.set("cache-control", "no-store");
  return new Response(upstream.body, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

async function sendCodex(
  request: Request,
  forwardedHeaders: Headers,
  credential: { accessToken: string; accountId: string },
): Promise<Response> {
  const headers = new Headers(forwardedHeaders);
  headers.set("authorization", `Bearer ${credential.accessToken}`);
  headers.set("chatgpt-account-id", credential.accountId);
  headers.set("originator", "coderouter");
  return await fetch(CODEX_UPSTREAM, {
    method: "POST",
    headers,
    body: request.body,
    duplex: "half",
    cache: "no-store",
  } as RequestInit & { duplex: "half" });
}

function rateLimitDelay(headers: Headers): number {
  const retryAfter = headers.get("retry-after");
  if (retryAfter && /^\d+$/.test(retryAfter)) {
    return Number(retryAfter) * 1_000;
  }
  for (const name of [
    "x-ratelimit-reset-requests",
    "x-ratelimit-reset-tokens",
  ]) {
    const raw = headers.get(name);
    if (!raw) continue;
    const seconds = /^(\d+(?:\.\d+)?)s$/.exec(raw)?.[1] ?? (/^\d+$/.test(raw) ? raw : null);
    if (seconds) return Math.ceil(Number(seconds) * 1_000);
  }
  return 60_000;
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const match = /^Bearer[ \t]+(.+)$/i.exec(authorization);
  return match?.[1]?.trim() || null;
}

function jsonError(
  error: string,
  status: number,
  headers?: HeadersInit,
): Response {
  return Response.json(
    { error },
    {
      status,
      headers: {
        "cache-control": "no-store",
        ...Object.fromEntries(new Headers(headers)),
      },
    },
  );
}
