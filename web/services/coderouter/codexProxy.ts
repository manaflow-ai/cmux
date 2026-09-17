import {
  authenticateRouteToken,
  markAccountCooldown,
  selectAccountForRequest,
} from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import { observeModelUsage, type ModelUsage } from "./responseUsage";

const CODEX_UPSTREAM = "https://chatgpt.com/backend-api/codex/responses";
const CODEX_MODELS_UPSTREAM = "https://chatgpt.com/backend-api/codex/models";
const ALLOWED_REQUEST_HEADERS = [
  "accept",
  "content-encoding",
  "content-type",
  "openai-beta",
  "openai-organization",
  "session_id",
  "user-agent",
] as const;

export async function proxyCodexRequest(request: Request): Promise<Response> {
  const startedAt = performance.now();
  const token = bearerToken(request);
  if (!token) {
    addCoderouterBreadcrumb("auth", "Route token missing", {}, "warning");
    return jsonError(
      "unauthorized",
      401,
      undefined,
      "Sign in with `cr login` and retry.",
      false,
    );
  }
  const identity = await authenticateRouteToken(token);
  if (!identity) {
    addCoderouterBreadcrumb("auth", "Route token rejected", {}, "warning");
    captureCoderouterEvent({
      event: "coderouter_auth_rejected",
      userId: "coderouter:anonymous",
      properties: { path: "responses", reason: "invalid_route_token" },
    });
    return jsonError(
      "unauthorized",
      401,
      undefined,
      "Your coderouter session expired or was revoked. Run `cr login` and retry.",
      false,
    );
  }
  addCoderouterBreadcrumb("auth", "Route token accepted", {
    path: "responses",
  });

  const forwardedHeaders = new Headers();
  for (const name of ALLOWED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) forwardedHeaders.set(name, value);
  }
  const attempted: string[] = [];
  let refreshRetries = 0;
  let upstream: Response | null = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await selectAccountForRequest(
      identity.teamId,
      "codex",
      attempted,
    );
    if (!account) break;
    attempted.push(account.id);
    addCoderouterBreadcrumb("routing", "Selected provider account", {
      provider: "codex",
      attempt: attempt + 1,
    });
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
    try {
      upstream = await sendCodex(request.clone(), forwardedHeaders, credential);
    } catch (error) {
      reportCoderouterFailure("upstream_transport", error, {
        provider: "codex",
        attempt: attempt + 1,
      });
      continue;
    }
    if (upstream.status === 401) {
      refreshRetries++;
      addCoderouterBreadcrumb(
        "refresh",
        "Refreshing rejected credential",
        {
          provider: "codex",
          attempt: attempt + 1,
        },
        "warning",
      );
      try {
        const refreshed = await freshCredential({
          teamId: identity.teamId,
          accountId: account.id,
          expectedRevision: account.vaultRevision,
          force: true,
        });
        if (refreshed.provider === "codex") {
          upstream = await sendCodex(
            request.clone(),
            forwardedHeaders,
            refreshed,
          );
        }
      } catch (error) {
        reportCoderouterFailure("provider_refresh", error, {
          provider: "codex",
          forced: true,
        });
        continue;
      }
    }
    if (upstream.status === 429) {
      reportCoderouterFailure(
        "provider_rate_limit",
        new Error("rate limited"),
        {
          provider: "codex",
          status: 429,
        },
      );
      await markAccountCooldown(account.id, rateLimitDelay(upstream.headers));
      continue;
    }
    break;
  }
  if (!upstream) {
    captureModelRequest({
      identity,
      request,
      startedAt,
      status: 503,
      attempted: attempted.length,
      refreshRetries,
      outcome: "no_usable_account",
      usage: null,
    });
    return jsonError(
      "no_usable_account",
      503,
      { "retry-after": "15" },
      "No healthy Codex subscription is currently available. Check `cr`, add an account with `cr add`, or retry shortly.",
      true,
    );
  }
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
  if (!responseHeaders.has("content-type")) {
    responseHeaders.set("content-type", "text/event-stream; charset=utf-8");
  }
  responseHeaders.set("cache-control", "no-store");
  const status = upstream.status;
  const observedBody = observeModelUsage(upstream.body, (usage) => {
    captureModelRequest({
      identity,
      request,
      startedAt,
      status,
      attempted: attempted.length,
      refreshRetries,
      outcome: status >= 200 && status < 300 ? "success" : "upstream_error",
      usage,
    });
  });
  return new Response(observedBody, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

type CodexModelsDependencies = {
  readonly authenticate: typeof authenticateRouteToken;
  readonly select: typeof selectAccountForRequest;
  readonly credential: typeof freshCredential;
  readonly cooldown: typeof markAccountCooldown;
  readonly providerRead: typeof fetchProviderRead;
};

export function createCodexModelsProxy(dependencies: CodexModelsDependencies) {
  return async (request: Request): Promise<Response> => {
    const token = bearerToken(request);
    if (!token) {
      return jsonError(
        "unauthorized",
        401,
        undefined,
        "Sign in with `cr login` and retry.",
        false,
      );
    }
    const identity = await dependencies.authenticate(token);
    if (!identity) {
      return jsonError(
        "unauthorized",
        401,
        undefined,
        "Your coderouter session expired or was revoked. Run `cr login` and retry.",
        false,
      );
    }

    const attempted: string[] = [];
    let upstream: Response | null = null;
    for (let attempt = 0; attempt < 8; attempt++) {
      const account = await dependencies.select(
        identity.teamId,
        "codex",
        attempted,
      );
      if (!account) break;
      attempted.push(account.id);
      let credential;
      try {
        credential = await dependencies.credential({
          teamId: identity.teamId,
          accountId: account.id,
          expectedRevision: account.vaultRevision,
        });
      } catch {
        continue;
      }
      if (credential.provider !== "codex") continue;
      const upstreamUrl = new URL(CODEX_MODELS_UPSTREAM);
      upstreamUrl.search = new URL(request.url).search;
      try {
        upstream = await dependencies.providerRead(() =>
          fetch(upstreamUrl, {
            headers: {
              authorization: `Bearer ${credential.accessToken}`,
              "chatgpt-account-id": credential.accountId,
              originator: "codex_cli_rs",
              "user-agent": request.headers.get("user-agent") ?? "coderouter",
            },
            cache: "no-store",
            signal: AbortSignal.timeout(5_000),
          }),
        );
      } catch (error) {
        reportCoderouterFailure("upstream_transport", error, {
          provider: "codex",
          operation: "models",
          attempt: attempt + 1,
        });
        continue;
      }
      if (upstream.status === 429) {
        reportCoderouterFailure(
          "provider_rate_limit",
          new Error("rate limited"),
          {
            provider: "codex",
            status: 429,
          },
        );
        await dependencies.cooldown(
          account.id,
          rateLimitDelay(upstream.headers),
        );
        continue;
      }
      break;
    }
    if (!upstream) {
      return jsonError(
        "no_usable_account",
        503,
        { "retry-after": "15" },
        "No healthy Codex subscription is currently available. Check `cr`, add an account with `cr add`, or retry shortly.",
        true,
      );
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "cache-control": "no-store",
        "content-type":
          upstream.headers.get("content-type") ?? "application/json",
      },
    });
  };
}

export const proxyCodexModels = createCodexModelsProxy({
  authenticate: authenticateRouteToken,
  select: selectAccountForRequest,
  credential: freshCredential,
  cooldown: markAccountCooldown,
  providerRead: fetchProviderRead,
});

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
    const seconds =
      /^(\d+(?:\.\d+)?)s$/.exec(raw)?.[1] ?? (/^\d+$/.test(raw) ? raw : null);
    if (seconds) return Math.ceil(Number(seconds) * 1_000);
  }
  return 60_000;
}

function bearerToken(request: Request): string | null {
  const routed = request.headers.get("x-coderouter-route-token")?.trim();
  if (routed) return routed;
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const match = /^Bearer[ \t]+(.+)$/i.exec(authorization);
  return match?.[1]?.trim() || null;
}

function jsonError(
  error: string,
  status: number,
  headers?: HeadersInit,
  message?: string,
  retryable = false,
): Response {
  return Response.json(
    { error, message: message ?? error, retryable },
    {
      status,
      headers: {
        "cache-control": "no-store",
        ...Object.fromEntries(new Headers(headers)),
      },
    },
  );
}

function captureModelRequest(input: {
  readonly identity: { readonly teamId: string; readonly stackUserId: string };
  readonly request: Request;
  readonly startedAt: number;
  readonly status: number;
  readonly attempted: number;
  readonly refreshRetries: number;
  readonly outcome: string;
  readonly usage: ModelUsage | null;
}): void {
  addCoderouterBreadcrumb(
    "request",
    "Model request completed",
    {
      provider: "codex",
      status: input.status,
      outcome: input.outcome,
      attempts: input.attempted,
      duration_ms: Math.round(performance.now() - input.startedAt),
    },
    input.status >= 500 ? "error" : input.status >= 400 ? "warning" : "info",
  );
  captureCoderouterEvent({
    event: "coderouter_model_request_completed",
    userId: input.identity.stackUserId,
    teamId: input.identity.teamId,
    properties: {
      provider: "codex",
      agent: agentFromUserAgent(input.request.headers.get("user-agent")),
      outcome: input.outcome,
      status: input.status,
      attempt_count: input.attempted,
      refresh_retry_count: input.refreshRetries,
      duration_ms: Math.round(performance.now() - input.startedAt),
      model: input.usage?.model ?? "unknown",
      input_tokens: input.usage?.inputTokens ?? 0,
      cached_input_tokens: input.usage?.cachedInputTokens ?? 0,
      output_tokens: input.usage?.outputTokens ?? 0,
      total_tokens: input.usage?.totalTokens ?? 0,
      actual_cost_usd: 0,
      cost_basis: "subscription_included",
    },
  });
}

function agentFromUserAgent(value: string | null): string {
  const normalized = value?.toLowerCase() ?? "";
  if (normalized.includes("codex")) return "codex";
  if (normalized.includes("pi")) return "pi";
  if (normalized.includes("opencode")) return "opencode";
  return "other";
}
