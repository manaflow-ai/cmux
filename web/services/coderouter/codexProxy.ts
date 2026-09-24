import { accountAccessForIdentity } from "./accountAccess";
import {
  authenticateRouteToken,
  markAccountCooldown,
  selectAccountForRequest,
  selectAccountForSession,
} from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { RESPONSES_PROVIDERS, type CodeRouterCredential } from "./types";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import {
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import { usageOriginFromHeaders } from "./usageOrigin";
import { isStreamingResponse, observeModelUsage, type ModelUsage } from "./responseUsage";
import {
  currentCoderouterRequestId,
  recordCoderouterOutcome,
  recordCoderouterSpan,
} from "./requestTelemetry";
import {
  authenticateCoderouterCredential,
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
const OPENAI_UPSTREAM = "https://api.openai.com/v1/responses";
const OPENAI_MODELS_UPSTREAM = "https://api.openai.com/v1/models";
const OPENROUTER_UPSTREAM = "https://openrouter.ai/api/v1/responses";
const OPENROUTER_MODELS_UPSTREAM = "https://openrouter.ai/api/v1/models";
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
  readonly cooldown: (
    accountId: string,
    durationMs: number,
    signal?: AbortSignal,
    failureCode?: string,
  ) => Promise<void>;
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
 * Capacity errors can arrive inside a successful streaming response. Keep the
 * pre-output probe small and bounded: provider error events are headers-sized,
 * while generated output must start flowing immediately after the first
 * non-error event.
 */
const MAX_PREOUTPUT_PROBE_BYTES = 64 * 1024;
const CAPACITY_COOLDOWN_MS = 60_000;
const WORKSPACE_QUOTA_COOLDOWN_MS = 60 * 60_000;
const PREOUTPUT_PROBE_IDLE_MS = 500;

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
  authenticate: authenticateCoderouterCredential,
  select: selectAccountForSession,
  credential: freshCredential,
  cooldown: markAccountCooldown,
});

// oxlint-disable-next-line complexity -- Routing keeps authentication, refresh, capacity, and deadline transitions in one request boundary.
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
          access: accountAccessForIdentity(identity),
          provider: RESPONSES_PROVIDERS,
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
    if (!servesResponses(credential)) continue;
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
      upstream = await sendResponses(
        request.clone(),
        forwardedHeaders,
        credential,
        runtime.fetch,
        headersTimeoutMs,
      );
      recordCoderouterSpan({
        name: "upstream_attempt",
        startedAt: upstreamStartedAt,
        attributes: { provider: credential.provider, attempt: attempt + 1, status: upstream.status },
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
          upstream = await sendResponses(
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
      // A Codex usage-limit response commonly uses 429 too. Inspect it before
      // applying the generic rate-limit path so a workspace quota gets the
      // provider reset/holdout policy instead of a one-minute retry loop.
      const probed = await probeCodexCapacity(upstream, request.signal);
      if (probed.kind === "capacity") {
        reportCoderouterFailure(
          probed.failureCode === "usage_limit_exceeded" ? "provider_usage" : "provider_rate_limit",
          new Error(`provider ${probed.failureCode}`),
          { provider: "codex", capacity: true, capacity_reason: probed.failureCode, status: 429 },
        );
        const cooldownResult = await coolDownCapacityAccount(
          dependencies,
          account.id,
          probed,
          request,
          upstreamHeaderDeadlineAt,
          runtime,
        );
        if (cooldownResult === "deadline") {
          failureStage = "upstream_transport";
          upstream = null;
          break;
        }
        upstream = null;
        continue;
      }
      upstream = probed.kind === "response" ? probed.response : upstream;
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
    // Providers do not consistently use 429 for model capacity. Codex has
    // returned the same capacity/quota error as a 400 or 503, sometimes as a
    // small JSON body and sometimes as an SSE error event. Treat that signal
    // like a rate limit before returning it to the caller so another account
    // can serve the request.
    if (upstream.status < 200 || upstream.status >= 300) {
      const probed = await probeCodexCapacity(upstream, request.signal);
      if (probed.kind === "capacity") {
        const cooldownResult = await coolDownCapacityAccount(
          dependencies,
          account.id,
          probed,
          request,
          upstreamHeaderDeadlineAt,
          runtime,
        );
        if (cooldownResult === "deadline") {
          failureStage = "upstream_transport";
          upstream = null;
          break;
        }
        upstream = null;
        continue;
      }
      upstream = probed.response;
    }
    if (isStreamingResponse(upstream)) {
      const probed = await probeCodexCapacity(upstream, request.signal);
      if (probed.kind === "capacity") {
        recordCoderouterSpan({
          name: "capacity_failover",
          startedAt: performance.now(),
          error: "provider_capacity",
          attributes: {
            provider: "codex",
            attempt: attempt + 1,
            retry_after_ms: capacityCooldownMs(probed),
            capacity_reason: probed.failureCode,
          },
        });
        addCoderouterBreadcrumb("routing", "Provider capacity; moving to another account", {
          provider: "codex",
          attempt: attempt + 1,
        }, "warning");
        reportCoderouterFailure(probed.failureCode === "usage_limit_exceeded" ? "provider_usage" : "provider_rate_limit", new Error("provider capacity"), {
          provider: "codex",
          capacity: true,
          capacity_reason: probed.failureCode,
          attempt: attempt + 1,
          request_id: requestId,
        });
        const cooldownResult = await coolDownCapacityAccount(
          dependencies,
          account.id,
          probed,
          request,
          upstreamHeaderDeadlineAt,
          runtime,
        );
        if (cooldownResult === "deadline") {
          failureStage = "upstream_transport";
          upstream = null;
          break;
        }
        upstream = null;
        continue;
      }
      upstream = probed.response;
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
      ...usageOriginFromHeaders(request.headers),
    });
  });
  return new Response(observedBody, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

type CodexCapacityProbe =
  | { readonly kind: "response"; readonly response: Response }
  | {
    readonly kind: "capacity";
    readonly failureCode: CodexCapacityFailureCode;
    readonly retryAfterMs?: number;
  };

type CodexCapacityFailureCode =
  | "usage_limit_exceeded"
  | "server_overloaded"
  | "rate_limit_exceeded"
  | "model_capacity";

function capacityCooldownMs(probe: Extract<CodexCapacityProbe, { kind: "capacity" }>): number {
  if (probe.retryAfterMs !== undefined) return probe.retryAfterMs;
  return probe.failureCode === "usage_limit_exceeded"
    ? WORKSPACE_QUOTA_COOLDOWN_MS
    : CAPACITY_COOLDOWN_MS;
}

async function coolDownCapacityAccount(
  dependencies: CodexResponsesDependencies,
  accountId: string,
  probe: Extract<CodexCapacityProbe, { kind: "capacity" }>,
  request: Request,
  deadlineAt: number,
  runtime: CodexResponsesRuntime,
): Promise<"cooled" | "deadline"> {
  const failureCode = probe.failureCode;
  try {
    await withCoderouterOperationDeadline(
      request.signal,
      deadlineAt,
      runtime.now,
      (signal) => dependencies.cooldown(
        accountId,
        capacityCooldownMs(probe),
        signal,
        failureCode,
      ),
    );
  } catch (error) {
    if (request.signal.aborted) throw error;
    if (error instanceof CoderouterOperationDeadlineError) {
      return "deadline";
    }
    throw error;
  }
  return "cooled";
}

/**
 * Inspects only the beginning of an SSE/NDJSON response. A capacity event is
 * safe to replay before any model output has been exposed; after the first
 * non-error event the response is returned with its bytes preserved. This
 * avoids replaying partial generations or consuming an upstream stream that
 * the caller still needs to read.
 */
// oxlint-disable-next-line complexity -- The bounded probe must preserve stream bytes while classifying SSE/NDJSON and cancellation outcomes.
async function probeCodexCapacity(
  response: Response,
  signal: AbortSignal,
): Promise<CodexCapacityProbe> {
  const body = response.body;
  if (!body) return { kind: "response", response };
  const reader = body.getReader();
  const format = codexResponseStreamFormat(response);
  const chunks: Uint8Array[] = [];
  let total = 0;
  let text = "";
  let pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | undefined;
  const decoder = new TextDecoder();
  try {
    for (;;) {
      throwIfAbortedSignal(signal);
      const next = await readWithProbeTimeout(reader, PREOUTPUT_PROBE_IDLE_MS, signal);
      if ("timedOut" in next) {
        pendingRead = next.pending;
        break;
      }
      if (next.done) break;
      chunks.push(next.value);
      total += next.value.byteLength;
      text += decoder.decode(next.value, { stream: true });
      const verdict = classifyCodexCapacityPrefix(text, format);
      const unstructuredCapacity = verdict.kind === "waiting" && format !== "ndjson" && isCodexCapacityText(text);
      if (verdict.kind === "capacity" || unstructuredCapacity) {
        await reader.cancel();
        return verdict.kind === "capacity"
          ? verdict
          : {
            kind: "capacity",
            failureCode: codexCapacityFailureCode(text) ?? "model_capacity",
            retryAfterMs: retryAfterFromCodexText(text),
          };
      }
      if (verdict.kind === "output" || total >= MAX_PREOUTPUT_PROBE_BYTES) break;
    }
    text += decoder.decode();
    const finalVerdict = classifyCodexCapacityPrefix(format === "ndjson" ? text : `${text}\n\n`, format, true);
    const unstructuredCapacity = finalVerdict.kind === "waiting" && format !== "ndjson" && isCodexCapacityText(text);
    if (finalVerdict.kind === "capacity" || unstructuredCapacity) {
      await reader.cancel();
      return finalVerdict.kind === "capacity"
        ? finalVerdict
        : {
          kind: "capacity",
          failureCode: codexCapacityFailureCode(text) ?? "model_capacity",
          retryAfterMs: retryAfterFromCodexText(text),
        };
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  }
  let buffered = chunks.slice();
  let upstreamDone = false;
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const chunk = buffered.shift();
      if (chunk) {
        controller.enqueue(chunk);
        return;
      }
      if (upstreamDone) {
        controller.close();
        return;
      }
      const next = await (pendingRead ?? reader.read());
      pendingRead = undefined;
      if (next.done) {
        upstreamDone = true;
        controller.close();
      } else {
        controller.enqueue(next.value);
      }
    },
    async cancel(reason) {
      upstreamDone = true;
      await reader.cancel(reason);
    },
  });
  return { kind: "response", response: new Response(stream, { status: response.status, headers: response.headers }) };
}

async function readWithProbeTimeout(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  timeoutMs: number,
  signal: AbortSignal,
): Promise<ReadableStreamReadResult<Uint8Array> | {
  readonly timedOut: true;
  readonly pending: Promise<ReadableStreamReadResult<Uint8Array>>;
}> {
  throwIfAbortedSignal(signal);
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  const raceSignal = AbortSignal.any([signal, timeoutSignal]);
  const pending = reader.read();
  let onAbort: (() => void) | undefined;
  const cancellation = new Promise<never>((_, reject) => {
    onAbort = () => {
      if (signal.aborted) {
        reject(signal.reason ?? new DOMException("The operation was aborted.", "AbortError"));
      } else {
        reject(new ProbeIdleTimeout());
      }
    };
    if (raceSignal.aborted) onAbort();
    else raceSignal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    return await Promise.race([pending, cancellation]);
  } catch (error) {
    if (error instanceof ProbeIdleTimeout) {
      // A quiet stream is handed back to the caller after the bounded probe.
      return { timedOut: true, pending };
    }
    throw error;
  } finally {
    if (onAbort) raceSignal.removeEventListener("abort", onAbort);
  }
}

class ProbeIdleTimeout extends Error {}

function throwIfAbortedSignal(signal: AbortSignal): void {
  if (!signal.aborted) return;
  throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

type CodexResponseStreamFormat = "sse" | "ndjson";

function codexResponseStreamFormat(response: Response): CodexResponseStreamFormat {
  const mediaType = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  return mediaType === "application/x-ndjson" ? "ndjson" : "sse";
}

function classifyCodexCapacityPrefix(
  text: string,
  format: CodexResponseStreamFormat = "sse",
  complete = false,
):
  | { readonly kind: "waiting" }
  | { readonly kind: "output" }
  | { readonly kind: "capacity"; readonly failureCode: CodexCapacityFailureCode; readonly retryAfterMs?: number } {
  if (format === "ndjson") return classifyCodexNdjsonPrefix(text, complete);
  const events = text.split(/\r?\n\r?\n/);
  for (const event of events.slice(0, -1)) {
    const data = event.match(/^data:\s*(.*)$/m)?.[1]?.trim();
    if (!data) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      continue;
    }
    if (isCodexOutputPayload(parsed)) return { kind: "output" };
    const failureCode = codexCapacityFailureCodeFromPayload(parsed);
    if (failureCode) {
      return { kind: "capacity", failureCode, retryAfterMs: retryAfterFromCodexPayload(parsed) };
    }
  }
  return { kind: "waiting" };
}

/** Parses complete newline-delimited JSON records without treating a partial trailing line as an event. */
function classifyCodexNdjsonPrefix(
  text: string,
  complete: boolean,
): Extract<ReturnType<typeof classifyCodexCapacityPrefix>, { readonly kind: "waiting" | "output" | "capacity" }> {
  const lines = text.split(/\r?\n/);
  if (!complete) lines.pop();
  for (const line of lines) {
    const data = line.trim();
    if (!data) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      continue;
    }
    if (isCodexOutputPayload(parsed)) return { kind: "output" };
    const failureCode = codexCapacityFailureCodeFromPayload(parsed);
    if (failureCode) {
      return { kind: "capacity", failureCode, retryAfterMs: retryAfterFromCodexPayload(parsed) };
    }
  }
  return { kind: "waiting" };
}

// oxlint-disable-next-line complexity -- Provider error payloads are recursively inspected without scanning generated output text.
function codexCapacityFailureCodeFromPayload(value: unknown, errorContext = false): CodexCapacityFailureCode | undefined {
  if (!value || typeof value !== "object") return undefined;
  const object = value as Record<string, unknown>;
  const type = typeof object.type === "string" ? object.type : undefined;
  const errorLike = errorContext || type?.toLowerCase() === "error" || type?.toLowerCase().endsWith(".error") ||
    "error" in object || "codex_error_info" in object;
  for (const candidate of [object.type, object.code, object.codex_error_info]) {
    if (typeof candidate === "string") {
      const failureCode = codexCapacityFailureCode(candidate);
      if (failureCode) return failureCode;
    }
  }
  if (errorLike && typeof object.message === "string") {
    const failureCode = codexCapacityFailureCode(object.message);
    if (failureCode) return failureCode;
  }
  for (const [key, candidate] of Object.entries(object)) {
    if (typeof candidate === "object" && candidate !== null) {
      const failureCode = codexCapacityFailureCodeFromPayload(candidate, errorLike || key === "error");
      if (failureCode) return failureCode;
    }
  }
  return undefined;
}

function isCodexCapacityPayload(value: unknown): boolean {
  const text = JSON.stringify(value).toLowerCase();
  return isCodexCapacityText(text);
}

function isCodexCapacityText(value: string): boolean {
  return codexCapacityFailureCode(value) !== undefined;
}

function retryAfterFromCodexText(value: string): number | undefined {
  try {
    return retryAfterFromCodexPayload(JSON.parse(value));
  } catch {
    return undefined;
  }
}

function codexCapacityFailureCode(value: string): CodexCapacityFailureCode | undefined {
  const text = value.toLowerCase();
  if (text.includes("usage_limit_reached") || text.includes("usage_limit_exceeded")) return "usage_limit_exceeded";
  if (text.includes("rate_limit_exceeded")) return "rate_limit_exceeded";
  if (
    text.includes("server_overloaded") ||
    text.includes("server_is_overloaded") ||
    text.includes("overloaded_error") ||
    text.includes("temporarily overloaded")
  ) return "server_overloaded";
  if (text.includes("selected model is at capacity") || text.includes("model is at capacity") || text.includes("model_capacity") || text.includes("model capacity")) return "model_capacity";
  return undefined;
}

function isCodexOutputPayload(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const type = String((value as { type?: unknown }).type ?? "");
  // Any delta means bytes describing model output are now client-visible;
  // replaying after that point could duplicate a partial generation.
  return type.endsWith(".delta");
}

// oxlint-disable-next-line complexity -- Retry hints have several provider payload shapes that must remain explicit.
function retryAfterFromCodexPayload(value: unknown): number | undefined {
  if (!value || typeof value !== "object") return undefined;
  const object = value as Record<string, unknown>;
  const raw = object.retry_after_ms ?? object.retry_after;
  if (typeof raw === "number" && Number.isFinite(raw)) return Math.max(1_000, raw < 100 ? raw * 1_000 : raw);
  if (typeof raw === "string" && /^\d+(?:\.\d+)?s?$/.test(raw)) {
    const seconds = Number.parseFloat(raw);
    return Math.max(1_000, raw.endsWith("s") || seconds < 100 ? seconds * 1_000 : seconds);
  }
  const resetSeconds = object.resets_in_seconds;
  if (typeof resetSeconds === "number" && Number.isFinite(resetSeconds) && resetSeconds > 0) {
    return boundedCapacityDelay(resetSeconds * 1_000);
  }
  if (typeof resetSeconds === "string" && /^\d+(?:\.\d+)?$/.test(resetSeconds)) {
    return boundedCapacityDelay(Number.parseFloat(resetSeconds) * 1_000);
  }
  const resetAt = object.resets_at;
  const resetTime = typeof resetAt === "number"
    ? resetAt * 1_000
    : typeof resetAt === "string" && /^\d+$/.test(resetAt)
    ? Number.parseInt(resetAt, 10) * 1_000
    : typeof resetAt === "string" ? Date.parse(resetAt) : NaN;
  if (Number.isFinite(resetTime)) return boundedCapacityDelay(resetTime - Date.now());
  const reachedType = object.rate_limit_reached_type;
  if (typeof reachedType === "string" && reachedType.toLowerCase().startsWith("workspace_")) {
    return WORKSPACE_QUOTA_COOLDOWN_MS;
  }
  for (const nested of [object.error, object.response]) {
    const nestedRetry = retryAfterFromCodexPayload(nested);
    if (nestedRetry !== undefined) return nestedRetry;
  }
  return undefined;
}

function boundedCapacityDelay(delayMs: number): number {
  return Math.min(Math.max(Math.round(delayMs), 60_000), 8 * 24 * 60 * 60_000);
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
        RESPONSES_PROVIDERS,
        attempted,
        request.signal,
        accountAccessForIdentity(identity),
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
      if (!servesResponses(credential)) continue;
      const models = modelsRequest(credential, request);
      const upstreamStartedAt = performance.now();
      try {
        upstream = await dependencies.providerRead(() =>
          fetch(models.url, {
            headers: models.headers,
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
      if (upstream.status === 401) {
        await retireRejectedCredential(dependencies, identity.teamId, account);
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
  authenticate: authenticateCoderouterCredential,
  select: selectAccountForRequest,
  credential: freshCredential,
  cooldown: markAccountCooldown,
  providerRead: fetchProviderRead,
});

type ResponsesCredential = Extract<
  CodeRouterCredential,
  { provider: "codex" | "openai-apikey" | "openrouter-apikey" }
>;

function servesResponses(credential: CodeRouterCredential): credential is ResponsesCredential {
  return (RESPONSES_PROVIDERS as readonly string[]).includes(credential.provider);
}

/**
 * Forwards one Responses call to the account's own upstream. Codex sign-ins go
 * to the ChatGPT backend with the account header; an OpenAI key goes to the
 * public API; an OpenRouter key goes to OpenRouter, whose model catalog is
 * vendor-prefixed, so a bare OpenAI model id is rewritten to `openai/<id>`.
 */
async function sendResponses(
  request: Request,
  forwardedHeaders: Headers,
  credential: ResponsesCredential,
  fetchImpl: typeof fetch,
  headersTimeoutMs: number,
): Promise<Response> {
  const headers = new Headers(forwardedHeaders);
  let url = CODEX_UPSTREAM;
  let body: BodyInit | null = request.body;
  switch (credential.provider) {
    case "codex":
      headers.set("authorization", `Bearer ${credential.accessToken}`);
      headers.set("chatgpt-account-id", credential.accountId);
      headers.set("originator", "coderouter");
      break;
    case "openai-apikey":
      url = OPENAI_UPSTREAM;
      headers.set("authorization", `Bearer ${credential.apiKey}`);
      headers.delete("session_id");
      break;
    case "openrouter-apikey":
      url = OPENROUTER_UPSTREAM;
      headers.set("authorization", `Bearer ${credential.apiKey}`);
      headers.set("http-referer", "https://cmux.com");
      headers.set("x-title", "cmux coderouter");
      headers.delete("session_id");
      headers.delete("openai-beta");
      body = await openRouterBody(request);
      break;
  }
  // Bounded to headers only: a hung upstream fails over instead of holding
  // the function for the full maxDuration; the body streams unbounded.
  return await fetchWithHeadersTimeout(fetchImpl, url, {
    method: "POST",
    headers,
    body,
    signal: request.signal,
    duplex: "half",
    cache: "no-store",
  } as RequestInit & { duplex: "half" }, headersTimeoutMs);
}

/** Rewrites a bare model id to OpenRouter's `openai/<id>`; anything else passes through. */
async function openRouterBody(request: Request): Promise<BodyInit | null> {
  const text = await request.text();
  try {
    const parsed: unknown = JSON.parse(text);
    if (
      parsed && typeof parsed === "object" && !Array.isArray(parsed) &&
      typeof (parsed as { model?: unknown }).model === "string"
    ) {
      return JSON.stringify({ ...parsed, model: openRouterModelId((parsed as { model: string }).model) });
    }
  } catch {
    // Not JSON: forward as received and let OpenRouter answer.
  }
  return text;
}

export function openRouterModelId(model: string): string {
  return model.includes("/") ? model : `openai/${model}`;
}

/**
 * A 401 on model discovery: force a refresh so an expired sign-in rotates and
 * a rejected API key is marked broken, then let the loop pick another account.
 */
async function retireRejectedCredential(
  dependencies: Pick<CodexModelsDependencies, "credential">,
  teamId: string,
  account: { readonly id: string; readonly vaultRevision: number },
): Promise<void> {
  try {
    await dependencies.credential({
      teamId,
      accountId: account.id,
      expectedRevision: account.vaultRevision,
      force: true,
    });
  } catch {
    // Busy or broken: either way this account is not used for this request.
  }
}

function modelsRequest(
  credential: ResponsesCredential,
  request: Request,
): { readonly url: URL; readonly headers: Record<string, string> } {
  const userAgent = request.headers.get("user-agent") ?? "coderouter";
  switch (credential.provider) {
    case "codex": {
      const url = new URL(CODEX_MODELS_UPSTREAM);
      url.search = new URL(request.url).search;
      return {
        url,
        headers: {
          authorization: `Bearer ${credential.accessToken}`,
          "chatgpt-account-id": credential.accountId,
          originator: "codex_cli_rs",
          "user-agent": userAgent,
        },
      };
    }
    case "openai-apikey":
      return {
        url: new URL(OPENAI_MODELS_UPSTREAM),
        headers: { authorization: `Bearer ${credential.apiKey}`, "user-agent": userAgent },
      };
    case "openrouter-apikey":
      return {
        url: new URL(OPENROUTER_MODELS_UPSTREAM),
        headers: {
          authorization: `Bearer ${credential.apiKey}`,
          "http-referer": "https://cmux.com",
          "x-title": "cmux coderouter",
          "user-agent": userAgent,
        },
      };
  }
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
  readonly identity?: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId" | "apiKeyId">;
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
    apiKeyId: input.identity?.apiKeyId,
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
  identity: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId" | "apiKeyId">,
  usage: ModelUsage | null,
  ledger: {
    readonly requestId: string;
    readonly agent: string;
    readonly status: number;
    readonly durationMs?: number;
    readonly streamed?: boolean;
    readonly workspaceId?: string | null;
    readonly surfaceId?: string | null;
  },
): void {
  if (!usage || usage.totalTokens === 0) return;
  recordUsageEvent({
    requestId: ledger.requestId,
    teamId: identity.teamId,
    stackUserId: identity.stackUserId,
    apiKeyId: identity.apiKeyId,
    vmId: identity.vmId,
    provider: "codex",
    agent: ledger.agent,
    model: usage.model,
    workspaceId: ledger.workspaceId,
    surfaceId: ledger.surfaceId,
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
