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
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import { isStreamingResponse, observeModelUsage, type ModelUsage } from "./responseUsage";
import {
  currentCoderouterRequestId,
  recordCoderouterOutcome,
  recordCoderouterSpan,
} from "./requestTelemetry";
import {
  authenticateRequestRouteToken,
  type RouteTokenAuthFailure,
  type RouteTokenIdentity,
} from "./routeTokenAuth";
import {
  CoderouterOperationDeadlineError,
  CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS,
  fetchWithHeadersTimeout,
  remainingUpstreamHeadersTimeoutMs,
  upstreamHeadersTimeoutMs,
  withCoderouterOperationDeadline,
} from "./upstreamFetch";

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

/** Runtime seams used by tests to exercise request-wide timeout behavior. */
export type CodexResponsesRuntimeOverrides = {
  readonly fetch?: typeof fetch;
  readonly now?: () => number;
  readonly upstreamHeadersBudgetMs?: number;
  readonly upstreamHeadersTimeoutMs?: number;
};

type CodexResponsesRuntime = {
  readonly fetch: typeof fetch;
  readonly now: () => number;
  readonly upstreamHeadersBudgetMs: number;
  readonly upstreamHeadersTimeoutMs: number;
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
  input: { teamId: string; accountId: string; expectedRevision: number; signal?: AbortSignal },
  sticky: boolean,
): Promise<Awaited<ReturnType<CodexResponsesDependencies["credential"]>>> {
  for (let attempt = 0; ; attempt++) {
    throwIfAborted(input.signal);
    try {
      return await dependencies.credential(input);
    } catch (error) {
      const busy = error && typeof error === "object" && "_tag" in error &&
        (error as { _tag: string })._tag === "CodeRouterRefreshBusy";
      if (!busy || !sticky || attempt >= STICKY_REFRESH_RETRIES) throw error;
      await waitForRetry(input.signal);
    }
  }
}

async function waitForRetry(signal: AbortSignal | undefined): Promise<void> {
  if (!signal) {
    await new Promise((resolve) => setTimeout(resolve, STICKY_REFRESH_RETRY_DELAY_MS));
    return;
  }
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, STICKY_REFRESH_RETRY_DELAY_MS);
    const abort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      reject(signal.reason ?? new DOMException("The operation was aborted.", "AbortError"));
    };
    if (signal.aborted) {
      abort();
      return;
    }
    signal.addEventListener("abort", abort, { once: true });
  });
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (!signal?.aborted) return;
  throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

export function createCodexResponsesProxy(
  dependencies: CodexResponsesDependencies,
  runtimeOverrides: CodexResponsesRuntimeOverrides = {},
): (request: Request) => Promise<Response> {
  const runtime: CodexResponsesRuntime = {
    fetch: runtimeOverrides.fetch ?? ((input, init) => fetch(input, init)),
    now: runtimeOverrides.now ?? (() => performance.now()),
    upstreamHeadersBudgetMs: runtimeOverrides.upstreamHeadersBudgetMs ?? CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS,
    upstreamHeadersTimeoutMs: runtimeOverrides.upstreamHeadersTimeoutMs ?? upstreamHeadersTimeoutMs(),
  };
  return async (request) => proxyCodexRequestWith(dependencies, runtime, request);
}

export const proxyCodexRequest = createCodexResponsesProxy({
  authenticate: authenticateRouteToken,
  select: selectAccountForSession,
  credential: freshCredential,
  cooldown: markAccountCooldown,
});

async function proxyCodexRequestWith(
  dependencies: CodexResponsesDependencies,
  runtime: CodexResponsesRuntime,
  request: Request,
): Promise<Response> {
  const startedAt = performance.now();
  const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
  const requestId = currentCoderouterRequestId();
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
    throwIfRequestAborted(request);
    if (remainingUpstreamHeadersTimeoutMs(
      upstreamHeaderDeadlineAt,
      runtime.now(),
      runtime.upstreamHeadersTimeoutMs,
    ) === null) {
      failureStage = "upstream_transport";
      break;
    }
    const selectStartedAt = performance.now();
    let account: Awaited<ReturnType<CodexResponsesDependencies["select"]>>;
    try {
      account = await withCoderouterOperationDeadline(
        request.signal,
        upstreamHeaderDeadlineAt,
        runtime.now,
        (signal) => dependencies.select({
          teamId: identity.teamId,
          provider: "codex",
          sessionKey,
          excludedAccountIds: attempted,
          signal,
        }),
      );
    } catch (error) {
      if (request.signal.aborted) throw error;
      recordCoderouterSpan({
        name: "account_selection",
        startedAt: selectStartedAt,
        error: error instanceof CoderouterOperationDeadlineError
          ? "deadline_exceeded"
          : error instanceof Error ? error.name : "select_failed",
        attributes: {
          provider: "codex",
          attempt: attempt + 1,
          ...(error instanceof CoderouterOperationDeadlineError ? { timeout_ms: error.timeoutMs } : {}),
        },
      });
      if (error instanceof CoderouterOperationDeadlineError) {
        failureStage = "account_selection";
        break;
      }
      throw error;
    }
    recordCoderouterSpan({
      name: "account_selection",
      startedAt: selectStartedAt,
      attributes: { provider: "codex", attempt: attempt + 1, sticky: account?.sticky ?? false, healthy: account !== null },
    });
    if (!account) break;
    attempted.push(account.id);
    addCoderouterBreadcrumb("routing", "Selected provider account", {
      provider: "codex",
      attempt: attempt + 1,
      sticky: account.sticky,
    });
    let credential;
    const credentialStartedAt = performance.now();
    try {
      credential = await withCoderouterOperationDeadline(
        request.signal,
        upstreamHeaderDeadlineAt,
        runtime.now,
        (signal) => credentialWithStickyPatience(
          dependencies,
          {
            teamId: identity.teamId,
            accountId: account.id,
            expectedRevision: account.vaultRevision,
            signal,
          },
          account.sticky,
        ),
      );
      recordCoderouterSpan({ name: "credential", startedAt: credentialStartedAt, attributes: { provider: "codex", attempt: attempt + 1 } });
    } catch (error) {
      if (request.signal.aborted) throw error;
      failureStage = "credential_refresh";
      const tag = error && typeof error === "object" && "_tag" in error
        ? String((error as { _tag: unknown })._tag)
        : undefined;
      recordCoderouterSpan({
        name: "credential",
        startedAt: credentialStartedAt,
        error: error instanceof CoderouterOperationDeadlineError
          ? "deadline_exceeded"
          : tag ?? "credential_failed",
        attributes: {
          provider: "codex",
          attempt: attempt + 1,
          ...(error instanceof CoderouterOperationDeadlineError ? { timeout_ms: error.timeoutMs } : {}),
        },
      });
      if (error instanceof CoderouterOperationDeadlineError) break;
      if (tag === "CodeRouterRefreshBusy") continue;
      if (tag === "CodeRouterCredentialBroken") continue;
      throw error;
    }
    if (credential.provider !== "codex") continue;
    throwIfRequestAborted(request);
    const headersTimeoutMs = remainingUpstreamHeadersTimeoutMs(
      upstreamHeaderDeadlineAt,
      runtime.now(),
      runtime.upstreamHeadersTimeoutMs,
    );
    if (headersTimeoutMs === null) {
      failureStage = "upstream_transport";
      break;
    }
    const upstreamStartedAt = performance.now();
    try {
      upstream = await sendCodex(
        request.clone(),
        forwardedHeaders,
        credential,
        runtime.fetch,
        headersTimeoutMs,
      );
      recordCoderouterSpan({
        name: "upstream_attempt",
        startedAt: upstreamStartedAt,
        attributes: { provider: "codex", attempt: attempt + 1, status: upstream.status },
      });
    } catch (error) {
      if (request.signal.aborted) throw error;
      failureStage = "upstream_transport";
      recordCoderouterSpan({
        name: "upstream_attempt",
        startedAt: upstreamStartedAt,
        error: error instanceof Error ? error.name : "transport",
        attributes: { provider: "codex", attempt: attempt + 1 },
      });
      reportCoderouterFailure("upstream_transport", error, {
        provider: "codex",
        attempt: attempt + 1,
        request_id: requestId,
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
      const refreshStartedAt = performance.now();
      try {
        const refreshed = await withCoderouterOperationDeadline(
          request.signal,
          upstreamHeaderDeadlineAt,
          runtime.now,
          (signal) => dependencies.credential({
            teamId: identity.teamId,
            accountId: account.id,
            expectedRevision: account.vaultRevision,
            force: true,
            signal,
          }),
        );
        recordCoderouterSpan({ name: "credential_refresh", startedAt: refreshStartedAt, attributes: { provider: "codex", forced: true } });
        if (refreshed.provider === "codex") {
          const retryHeadersTimeoutMs = remainingUpstreamHeadersTimeoutMs(
            upstreamHeaderDeadlineAt,
            runtime.now(),
            runtime.upstreamHeadersTimeoutMs,
          );
          if (retryHeadersTimeoutMs === null) {
            failureStage = "upstream_transport";
            upstream = null;
            break;
          }
          const retryStartedAt = performance.now();
          upstream = await sendCodex(
            request.clone(),
            forwardedHeaders,
            refreshed,
            runtime.fetch,
            retryHeadersTimeoutMs,
          );
          recordCoderouterSpan({
            name: "upstream_attempt",
            startedAt: retryStartedAt,
            attributes: { provider: "codex", attempt: attempt + 1, status: upstream.status, forced: true },
          });
        }
      } catch (error) {
        if (request.signal.aborted) throw error;
        failureStage = "credential_refresh";
        recordCoderouterSpan({
          name: "credential_refresh",
          startedAt: refreshStartedAt,
          error: error instanceof Error ? error.name : "refresh_failed",
          attributes: { provider: "codex", forced: true },
        });
        reportCoderouterFailure("provider_refresh", error, {
          provider: "codex",
          forced: true,
          request_id: requestId,
        });
        if (error instanceof CoderouterOperationDeadlineError) {
          upstream = null;
          break;
        }
        continue;
      }
    }
    if (upstream.status === 429) {
      const cooldownMs = rateLimitDelay(upstream.headers);
      reportCoderouterFailure(
        "provider_rate_limit",
        new Error("rate limited"),
        {
          provider: "codex",
          status: 429,
        },
      );
      try {
        await withCoderouterOperationDeadline(
          request.signal,
          upstreamHeaderDeadlineAt,
          runtime.now,
          (signal) => dependencies.cooldown(account.id, cooldownMs, signal),
        );
      } catch (error) {
        if (request.signal.aborted) throw error;
        if (error instanceof CoderouterOperationDeadlineError) {
          failureStage = "upstream_transport";
          break;
        }
        throw error;
      }
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
  const streamed = isStreamingResponse(upstream);
  captureRouteHealth({
    requestId,
    identity,
    request,
    startedAt,
    status,
    attempted: attempted.length,
    refreshRetries,
    outcome: status >= 200 && status < 300 ? "success" : "upstream_error",
    responseStreamed: streamed,
  });
  const agent = agentFromUserAgent(request.headers.get("user-agent"));
  const observedBody = observeModelUsage(upstream.body, (usage) => {
    captureModelUsage(identity, usage, {
      requestId,
      agent,
      status,
      durationMs: Math.round(performance.now() - startedAt),
      streamed,
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
    const auth = await authenticateRequestRouteToken(
      request,
      dependencies.authenticate,
    );
    if (!auth.ok) {
      captureCoderouterEvent({
        event: "coderouter_auth_rejected",
        properties: { surface: "models", reason: auth.reason },
      });
      recordCoderouterOutcome({ outcome: "unauthorized", failureStage: "auth", status: 401, provider: "codex", attempts: 0 });
      return unauthorizedError(auth.reason);
    }
    const identity = auth.identity;

    const attempted: string[] = [];
    let upstream: Response | null = null;
    let failureStage: "account_selection" | "credential_refresh" | "upstream_transport" = "account_selection";
    for (let attempt = 0; attempt < 8; attempt++) {
      const selectStartedAt = performance.now();
      const account = await dependencies.select(
        identity.teamId,
        "codex",
        attempted,
      );
      recordCoderouterSpan({
        name: "account_selection",
        startedAt: selectStartedAt,
        attributes: { provider: "codex", attempt: attempt + 1, healthy: account !== null },
      });
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
        failureStage = "credential_refresh";
        continue;
      }
      if (credential.provider !== "codex") continue;
      const upstreamUrl = new URL(CODEX_MODELS_UPSTREAM);
      upstreamUrl.search = new URL(request.url).search;
      const upstreamStartedAt = performance.now();
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
        recordCoderouterSpan({
          name: "upstream_attempt",
          startedAt: upstreamStartedAt,
          attributes: { provider: "codex", attempt: attempt + 1, status: upstream.status, surface: "models" },
        });
      } catch (error) {
        failureStage = "upstream_transport";
        recordCoderouterSpan({
          name: "upstream_attempt",
          startedAt: upstreamStartedAt,
          error: error instanceof Error ? error.name : "transport",
          attributes: { provider: "codex", attempt: attempt + 1, surface: "models" },
        });
        reportCoderouterFailure("upstream_transport", error, {
          provider: "codex",
          operation: "models",
          attempt: attempt + 1,
          request_id: currentCoderouterRequestId(),
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
          request.signal,
        );
        continue;
      }
      break;
    }
    if (!upstream) {
      const providerUnavailable = failureStage === "upstream_transport";
      recordCoderouterOutcome({
        outcome: providerUnavailable ? "provider_unavailable" : "no_usable_account",
        failureStage,
        status: 503,
        provider: "codex",
        attempts: attempted.length,
      });
      return jsonError(
        providerUnavailable ? "provider_unavailable" : "no_usable_account",
        503,
        { "retry-after": providerUnavailable ? "5" : "15" },
        providerUnavailable
          ? "The Codex provider could not be reached. Retry shortly."
          : "No healthy Codex subscription is currently available. Check `cr`, add an account with `cr add`, or retry shortly.",
        true,
      );
    }
    recordCoderouterOutcome({
      outcome: upstream.ok ? "success" : "upstream_error",
      failureStage: upstream.ok ? "none" : "upstream_response",
      status: upstream.status,
      provider: "codex",
      attempts: attempted.length,
    });
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
  fetchImpl: typeof fetch,
  headersTimeoutMs: number,
): Promise<Response> {
  const headers = new Headers(forwardedHeaders);
  headers.set("authorization", `Bearer ${credential.accessToken}`);
  headers.set("chatgpt-account-id", credential.accountId);
  headers.set("originator", "coderouter");
  // Bounded to headers only: a hung upstream fails over instead of holding
  // the function for the full maxDuration; the body streams unbounded.
  return await fetchWithHeadersTimeout(fetchImpl, CODEX_UPSTREAM, {
    method: "POST",
    headers,
    body: request.body,
    signal: request.signal,
    duplex: "half",
    cache: "no-store",
  } as RequestInit & { duplex: "half" }, headersTimeoutMs);
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

function throwIfRequestAborted(request: Request): void {
  if (!request.signal.aborted) return;
  throw request.signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
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
  readonly identity?: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId">;
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
  recordCoderouterOutcome({
    outcome: input.outcome,
    failureStage,
    status: input.status,
    provider: "codex",
    agent,
    attempts: input.attempted,
    refreshRetries: input.refreshRetries,
    responseStreamed: input.responseStreamed,
  });
  recordRouteEvent({
    requestId: input.requestId,
    teamId: input.identity?.teamId,
    stackUserId: input.identity?.stackUserId,
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
    readonly durationMs?: number;
    readonly streamed?: boolean;
  },
): void {
  if (!usage || usage.totalTokens === 0) return;
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
