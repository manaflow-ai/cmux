import { authenticateRouteToken, selectAccountForRequest } from "./repository";
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

  const account = await selectAccountForRequest(identity.teamId, "codex");
  if (!account) return jsonError("no_usable_account", 503);

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
      if (tag === "CodeRouterRefreshBusy") {
        return jsonError("credential_refresh_in_progress", 503, {
          "retry-after": "1",
        });
      }
      if (tag === "CodeRouterCredentialBroken") {
        return jsonError("no_usable_account", 503);
      }
    }
    throw error;
  }
  if (credential.provider !== "codex") {
    return jsonError("no_usable_account", 503);
  }

  const headers = new Headers();
  for (const name of ALLOWED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("authorization", `Bearer ${credential.accessToken}`);
  headers.set("chatgpt-account-id", credential.accountId);
  headers.set("originator", "coderouter");

  const upstream = await fetch(CODEX_UPSTREAM, {
    method: "POST",
    headers,
    body: request.body,
    // Required by Node fetch for a streaming request body.
    duplex: "half",
    cache: "no-store",
  } as RequestInit & { duplex: "half" });
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
