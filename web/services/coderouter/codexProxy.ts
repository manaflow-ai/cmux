import {
  authenticateRouteToken,
  markAccountCooldown,
  selectAccountForRequest,
  selectAccountForSession,
} from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import {
  newLedgerRequestId,
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import { observeModelUsage, type ModelUsage } from "./responseUsage";
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthFailure,
  type RouteTokenIdentity,
} from "./routeTokenAuth";

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

type CodexResponsesDependencies = {
  readonly authenticate: typeof authenticateRouteToken;
  readonly select: typeof selectAccountForSession;
  readonly credential: typeof freshCredential;
  readonly cooldown: typeof markAccountCooldown;
};

/**
 * The Codex CLI sends a stable `session_id` header for every request of one
 * agent session. That key pins the session to one account so the provider's
 * prompt cache stays warm across turns.
 */
function sessionKeyFromRequest(request: Request): string | null {
  const raw = request.headers.get("session_id")?.trim();
  if (!raw || raw.length > 512) return null;
  return raw;
}

const STICKY_REFRESH_RETRIES = 4;
const STICKY_REFRESH_RETRY_DELAY_MS = 500;

/**
 * A sticky session that hits a refresh already in flight should wait for the
 * winner's fresh credential rather than move to another account: a move
 * discards the session's prompt cache and re-bills its whole prefix, while
 * the in-flight refresh completes within seconds. Non-sticky requests keep
 * the fail-fast behavior.
 */
async function credentialWithStickyPatience(
  dependencies: Pick<CodexResponsesDependencies, "credential">,
  input: { teamId: string; accountId: string; expectedRevision: number },
  sticky: boolean,
): Promise<Awaited<ReturnType<CodexResponsesDependencies["credential"]>>> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await dependencies.credential(input);
    } catch (error) {
      const busy = error && typeof error === "object" && "_tag" in error &&
        (error as { _tag: string })._tag === "CodeRouterRefreshBusy";
      if (!busy || !sticky || attempt >= STICKY_REFRESH_RETRIES) throw error;
      await new Promise((resolve) =>
        setTimeout(resolve, STICKY_REFRESH_RETRY_DELAY_MS)
      );
    }
  }
}

export function createCodexResponsesProxy(
  dependencies: CodexResponsesDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => proxyCodexRequestWith(dependencies, request);
}

export const proxyCodexRequest = createCodexResponsesProxy({
  authenticate: authenticateRouteToken,
  select: selectAccountForSession,
  credential: freshCredential,
  cooldown: markAccountCooldown,
});

async function proxyCodexRequestWith(
  dependencies: CodexResponsesDependencies,
  request: Request,
): Promise<Response> {
  const startedAt = performance.now();
  const requestId = newLedgerRequestId();
  const auth = await authenticateRequestRouteToken(
    request,
    dependencies.authenticate,
  );
  if (!auth.ok) {
    addCoderouterBreadcrumb(
      "auth",
      AUTH_FAILURE_BREADCRUMBS[auth.reason],
      {},
      "warning",
    );
    captureCoderouterEvent({
      event: "coderouter_auth_rejected",
      properties: { surface: "responses", reason: auth.reason },
    });
    captureRouteHealth({
      requestId,
      request,
      startedAt,
      status: 401,
      attempted: 0,
      refreshRetries: 0,
      outcome: "unauthorized",
      failureStage: "auth",
      responseStreamed: false,
    });
    return unauthorizedError(auth.reason);
  }
  const identity = auth.identity;
  addCoderouterBreadcrumb("auth", "Route token accepted", {
    path: "responses",
    bound_to_vm: identity.vmId !== null,
  });

  const forwardedHeaders = new Headers();
  for (const name of ALLOWED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) forwardedHeaders.set(name, value);
  }
  const sessionKey = sessionKeyFromRequest(request);
  const attempted: string[] = [];
  let refreshRetries = 0;
  let failureStage: "account_selection" | "credential_refresh" | "upstream_transport" =
    "account_selection";
  let upstream: Response | null = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await dependencies.select({
      teamId: identity.teamId,
      provider: "codex",
      sessionKey,
      excludedAccountIds: attempted,
    });
    if (!account) break;
    attempted.push(account.id);
    addCoderouterBreadcrumb("routing", "Selected provider account", {
      provider: "codex",
      attempt: attempt + 1,
      sticky: account.sticky,
    });
    let credential;
    try {
      credential = await credentialWithStickyPatience(
        dependencies,
        {
          teamId: identity.teamId,
          accountId: account.id,
          expectedRevision: account.vaultRevision,
        },
        account.sticky,
      );
    } catch (error) {
      failureStage = "credential_refresh";
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
      failureStage = "upstream_transport";
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
        const refreshed = await dependencies.credential({
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
        failureStage = "credential_refresh";
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
      await dependencies.cooldown(account.id, rateLimitDelay(upstream.headers));
      continue;
    }
    break;
  }
  if (!upstream) {
    captureRouteHealth({
      requestId,
      identity,
      request,
      startedAt,
      status: 503,
      attempted: attempted.length,
      refreshRetries,
      outcome: "no_usable_account",
      failureStage,
      responseStreamed: false,
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
  captureRouteHealth({
    requestId,
    identity,
    request,
    startedAt,
    status,
    attempted: attempted.length,
    refreshRetries,
    outcome: status >= 200 && status < 300 ? "success" : "upstream_error",
    responseStreamed: upstream.body !== null,
  });
  const agent = agentFromUserAgent(request.headers.get("user-agent"));
  const observedBody = observeModelUsage(upstream.body, (usage) => {
    captureModelUsage(identity, usage, { requestId, agent, status });
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
    const auth = await authenticateRequestRouteToken(
      request,
      dependencies.authenticate,
    );
    if (!auth.ok) {
      captureCoderouterEvent({
        event: "coderouter_auth_rejected",
        properties: { surface: "models", reason: auth.reason },
      });
      return unauthorizedError(auth.reason);
    }
    const identity = auth.identity;

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

const AUTH_FAILURE_BREADCRUMBS: Record<RouteTokenAuthFailure, string> = {
  missing_route_token: "Route token missing",
  invalid_route_token: "Route token rejected",
  vm_mismatch: "Route token bound to another machine",
};

const AUTH_FAILURE_MESSAGES: Record<RouteTokenAuthFailure, string> = {
  missing_route_token: "Sign in with `cr login` and retry.",
  invalid_route_token:
    "Your coderouter session expired or was revoked. Run `cr login` and retry.",
  vm_mismatch:
    "This machine's coderouter credential does not match the machine it was issued to.",
};

function unauthorizedError(reason: RouteTokenAuthFailure): Response {
  return jsonError(
    "unauthorized",
    401,
    undefined,
    AUTH_FAILURE_MESSAGES[reason],
    false,
  );
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

function captureRouteHealth(input: {
  readonly requestId: string;
  readonly identity?: Pick<RouteTokenIdentity, "teamId" | "vmId">;
  readonly request: Request;
  readonly startedAt: number;
  readonly status: number;
  readonly attempted: number;
  readonly refreshRetries: number;
  readonly outcome:
    | "success"
    | "upstream_error"
    | "no_usable_account"
    | "unauthorized";
  readonly failureStage?:
    | "none"
    | "auth"
    | "account_selection"
    | "credential_refresh"
    | "upstream_transport"
    | "upstream_response";
  readonly responseStreamed: boolean;
}): void {
  const durationMs = Math.round(performance.now() - input.startedAt);
  const agent = agentFromUserAgent(input.request.headers.get("user-agent"));
  addCoderouterBreadcrumb(
    "request",
    "Model request completed",
    {
      provider: "codex",
      status: input.status,
      outcome: input.outcome,
      attempts: input.attempted,
      duration_ms: durationMs,
    },
    input.status >= 500 ? "error" : input.status >= 400 ? "warning" : "info",
  );
  const failureStage = input.outcome === "success"
    ? "none"
    : input.outcome === "unauthorized"
    ? "auth"
    : input.outcome === "no_usable_account"
    ? input.failureStage ?? "account_selection"
    : "upstream_response";
  // Capture as soon as the terminal route result is known. This is deliberately
  // independent of response consumption and token parsing.
  captureCoderouterEvent({
    event: "coderouter_route_health",
    teamId: input.identity?.teamId,
    properties: {
      provider: "codex",
      agent,
      outcome: input.outcome,
      failure_stage: failureStage,
      status: input.status,
      attempt_count: input.attempted,
      refresh_retry_count: input.refreshRetries,
      duration_ms: durationMs,
      response_streamed: input.responseStreamed,
      ...vmIdProperty(input.identity?.vmId ?? null),
    },
  });
  recordRouteEvent({
    requestId: input.requestId,
    teamId: input.identity?.teamId,
    vmId: input.identity?.vmId ?? null,
    provider: "codex",
    agent,
    outcome: input.outcome,
    failureStage,
    status: input.status,
    attemptCount: input.attempted,
    refreshRetryCount: input.refreshRetries,
    durationMs,
    responseStreamed: input.responseStreamed,
  });
}

function captureModelUsage(
  identity: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId">,
  usage: ModelUsage | null,
  ledger: {
    readonly requestId: string;
    readonly agent: string;
    readonly status: number;
  },
): void {
  if (!usage || usage.totalTokens === 0) return;
  captureCoderouterEvent({
    event: "coderouter_model_request_completed",
    teamId: identity.teamId,
    properties: {
      provider: "codex",
      model: usage.model ?? "unknown",
      input_tokens: usage.inputTokens,
      cached_input_tokens: usage.cachedInputTokens,
      output_tokens: usage.outputTokens,
      total_tokens: usage.totalTokens,
      ...vmIdProperty(identity.vmId),
    },
  });
  recordUsageEvent({
    requestId: ledger.requestId,
    teamId: identity.teamId,
    stackUserId: identity.stackUserId,
    vmId: identity.vmId,
    provider: "codex",
    agent: ledger.agent,
    model: usage.model,
    inputTokens: usage.inputTokens,
    cachedInputTokens: usage.cachedInputTokens,
    outputTokens: usage.outputTokens,
    totalTokens: usage.totalTokens,
    status: ledger.status,
  });
}

/** Per-VM attribution for bound tokens; omitted for unbound (CLI) tokens. */
function vmIdProperty(vmId: string | null): { vm_id?: string } {
  return vmId === null ? {} : { vm_id: vmId };
}

function agentFromUserAgent(value: string | null): string {
  const normalized = value?.toLowerCase() ?? "";
  if (normalized.includes("codex")) return "codex";
  if (normalized.includes("pi")) return "pi";
  if (normalized.includes("opencode")) return "opencode";
  return "other";
}
