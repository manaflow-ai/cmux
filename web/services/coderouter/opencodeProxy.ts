import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";

import { authenticateRouteToken, selectAccountForRequest } from "./repository";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import { isStreamingResponse, observeModelUsage } from "./responseUsage";
import {
  recordRouteEvent,
  recordUsageEvent,
} from "./usageLedger";
import {
  currentCoderouterRequestId,
  recordCoderouterOutcome,
  recordCoderouterSpan,
} from "./requestTelemetry";
import {
  CoderouterOperationDeadlineError,
  CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS,
  fetchWithHeadersTimeout,
  remainingUpstreamHeadersTimeoutMs,
  upstreamHeadersTimeoutMs,
  withCoderouterOperationDeadline,
} from "./upstreamFetch";
import {
  authenticateRequestRouteToken,
  VM_PLACEHOLDER_API_KEY,
  type RouteTokenAuthFailure,
  type RouteTokenIdentity,
} from "./routeTokenAuth";

const OPENCODE_CONSOLE = "https://console.opencode.ai";

type OpenCodeDependencies = {
  readonly authenticate: typeof authenticateRouteToken;
  readonly select: typeof selectAccountForRequest;
  readonly credential: typeof freshCredential;
  readonly remoteConfig: (accessToken: string, signal?: AbortSignal) => Promise<Record<string, unknown>>;
  readonly fetch?: typeof fetch;
  readonly resolveProviderURL?: typeof resolveProviderURL;
};

/** Runtime seams used by tests to exercise request-wide timeout behavior. */
export type OpenCodeProxyRuntimeOverrides = {
  readonly now?: () => number;
  readonly upstreamHeadersBudgetMs?: number;
  readonly upstreamHeadersTimeoutMs?: number;
};

type OpenCodeProxyRuntime = {
  readonly now: () => number;
  readonly upstreamHeadersBudgetMs: number;
  readonly upstreamHeadersTimeoutMs: number;
};

const defaultDependencies: OpenCodeDependencies = {
  authenticate: authenticateRouteToken,
  select: selectAccountForRequest,
  credential: freshCredential,
  remoteConfig,
  fetch,
};

const AUTH_FAILURE_MESSAGES: Record<RouteTokenAuthFailure, string> = {
  missing_route_token: "Sign in with `cr login` and retry.",
  invalid_route_token:
    "Your coderouter session expired or was revoked. Run `cr login` and retry.",
  vm_mismatch:
    "This machine's coderouter credential does not match the machine it was issued to.",
};

export async function openCodeClientConfig(
  request: Request,
  dependencies: OpenCodeDependencies = defaultDependencies,
  runtimeOverrides: OpenCodeProxyRuntimeOverrides = {},
): Promise<Response> {
  const runtime = resolveOpenCodeRuntime(runtimeOverrides);
  const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
  const auth = await authenticateRequestRouteToken(
    request,
    dependencies.authenticate,
  );
  if (!auth.ok) {
    captureAuthRejection("opencode_config", auth.reason);
    return apiError("unauthorized", AUTH_FAILURE_MESSAGES[auth.reason], 401, false);
  }
  let resolved: Awaited<ReturnType<typeof openCodeAccount>>;
  try {
    resolved = await withCoderouterOperationDeadline(
      request.signal,
      upstreamHeaderDeadlineAt,
      runtime.now,
      (signal) => openCodeAccount(auth.identity.teamId, dependencies, signal),
    );
  } catch (error) {
    if (request.signal.aborted) throw error;
    if (!(error instanceof CoderouterOperationDeadlineError)) {
      reportCoderouterFailure("rds", error, {
        provider: "opencode-go",
        operation: "select_opencode_account",
        request_id: currentCoderouterRequestId(),
      });
    }
    return apiError(
      "provider_unavailable",
      "coderouter could not load the team's OpenCode accounts. Retry shortly.",
      503,
      true,
    );
  }
  if (!resolved)
    return Response.json({ error: "no_usable_account" }, { status: 503 });
  let remote: Record<string, unknown>;
  try {
    remote = await withCoderouterOperationDeadline(
      request.signal,
      upstreamHeaderDeadlineAt,
      runtime.now,
      (signal) => dependencies.remoteConfig(resolved.credential.accessToken, signal),
    );
  } catch (error) {
    if (request.signal.aborted) throw error;
    reportCoderouterFailure("provider_usage", error, {
      provider: "opencode-go",
      operation: "load_opencode_config",
      request_id: currentCoderouterRequestId(),
    });
    return apiError(
      "provider_unavailable",
      "OpenCode configuration is temporarily unavailable. Retry shortly.",
      502,
      true,
    );
  }
  // The proxy origin comes from the serving request, not a hardcoded host,
  // so the config works on every deployment of this app (coderouter.dev,
  // the cmux origin Cloud VMs are minted against, previews, self-hosted).
  //
  // A VM-bound token never leaves the edge: the guest's config carries the
  // public placeholder key, and the edge injects the real token per request.
  const provider = rewriteProviders(
    remote,
    auth.identity.vmId === null ? auth.identity.token : VM_PLACEHOLDER_API_KEY,
    new URL(request.url).origin,
  );
  return Response.json(
    { provider },
    {
      headers: { "cache-control": "no-store" },
    },
  );
}

export async function proxyOpenCodeRequest(
  request: Request,
  providerId: string,
  path: readonly string[],
  dependencies: OpenCodeDependencies = defaultDependencies,
  runtimeOverrides: OpenCodeProxyRuntimeOverrides = {},
): Promise<Response> {
  const startedAt = performance.now();
  const runtime = resolveOpenCodeRuntime(runtimeOverrides);
  const upstreamHeaderDeadlineAt = runtime.now() + runtime.upstreamHeadersBudgetMs;
  const requestId = currentCoderouterRequestId();
  const authResult = await authenticateRequestRouteToken(
    request,
    dependencies.authenticate,
  );
  if (!authResult.ok) {
    captureAuthRejection("opencode_proxy", authResult.reason);
    captureOpenCodeHealth({
      requestId,
      startedAt,
      status: 401,
      outcome: "unauthorized",
      failureStage: "auth",
    });
    return apiError(
      "unauthorized",
      AUTH_FAILURE_MESSAGES[authResult.reason],
      401,
      false,
    );
  }
  const auth = authResult.identity;
  const selectStartedAt = performance.now();
  let resolved: Awaited<ReturnType<typeof openCodeAccount>>;
  try {
    resolved = await withCoderouterOperationDeadline(
      request.signal,
      upstreamHeaderDeadlineAt,
      runtime.now,
      (signal) => openCodeAccount(auth.teamId, dependencies, signal),
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
        provider: "opencode-go",
        ...(error instanceof CoderouterOperationDeadlineError ? { timeout_ms: error.timeoutMs } : {}),
      },
    });
    if (!(error instanceof CoderouterOperationDeadlineError)) {
      reportCoderouterFailure("rds", error, {
        provider: "opencode-go",
        operation: "select_opencode_account",
        request_id: requestId,
      });
    }
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 503,
      outcome: "provider_unavailable",
      failureStage: "account_selection",
    });
    return apiError(
      "provider_unavailable",
      "coderouter could not load the team's OpenCode accounts. Retry shortly.",
      503,
      true,
    );
  }
  recordCoderouterSpan({
    name: "account_selection",
    startedAt: selectStartedAt,
    attributes: { provider: "opencode-go", attempts: resolved?.attempts ?? 0, healthy: resolved !== null },
  });
  if (!resolved) {
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 503,
      outcome: "no_usable_account",
      failureStage: "account_selection",
    });
    return apiError(
      "no_usable_account",
      "No healthy OpenCode subscription is available. Check `cr`, add an account with `cr add`, or retry shortly.",
      503,
      true,
    );
  }
  let config: Record<string, unknown>;
  const configStartedAt = performance.now();
  try {
    config = await withCoderouterOperationDeadline(
      request.signal,
      upstreamHeaderDeadlineAt,
      runtime.now,
      (signal) => dependencies.remoteConfig(resolved.credential.accessToken, signal),
    );
    recordCoderouterSpan({ name: "provider_config", startedAt: configStartedAt, attributes: { provider: "opencode-go" } });
  } catch (error) {
    if (request.signal.aborted) throw error;
    recordCoderouterSpan({
      name: "provider_config",
      startedAt: configStartedAt,
      error: error instanceof CoderouterOperationDeadlineError
        ? "deadline_exceeded"
        : error instanceof Error ? error.name : "config_failed",
      attributes: {
        provider: "opencode-go",
        ...(error instanceof CoderouterOperationDeadlineError ? { timeout_ms: error.timeoutMs } : {}),
      },
    });
    reportCoderouterFailure("provider_usage", error, {
      provider: "opencode-go",
      operation: "config",
      request_id: requestId,
    });
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 502,
      outcome: "provider_unavailable",
      failureStage: "provider_config",
      attempts: resolved.attempts,
    });
    return apiError(
      "provider_unavailable",
      "OpenCode configuration is temporarily unavailable. Retry shortly.",
      502,
      true,
    );
  }
  const provider = config[providerId];
  if (!isRecord(provider)) {
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 404,
      outcome: "unknown_provider",
      failureStage: "provider_config",
      attempts: resolved.attempts,
    });
    return apiError(
      "unknown_provider",
      "This OpenCode provider is no longer available. Refresh OpenCode's provider list and retry.",
      404,
      false,
    );
  }
  const api = provider.api;
  const base = isRecord(api) ? api.url : undefined;
  if (typeof base !== "string" || !safeProviderURL(base)) {
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 502,
      outcome: "invalid_provider",
      failureStage: "provider_config",
      attempts: resolved.attempts,
    });
    return apiError(
      "invalid_provider",
      "OpenCode returned an unsafe or invalid provider endpoint.",
      502,
      false,
    );
  }
  const target = await (dependencies.resolveProviderURL ?? resolveProviderURL)(base);
  if (!target) {
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 502,
      outcome: "invalid_provider",
      failureStage: "provider_config",
      attempts: resolved.attempts,
    });
    return apiError(
      "invalid_provider",
      "OpenCode returned an unsafe or invalid provider endpoint.",
      502,
      false,
    );
  }
  target.pathname = `${target.pathname.replace(/\/+$/, "")}/${path
    .map(encodeURIComponent)
    .join("/")}`;
  target.search = new URL(request.url).search;

  const headers = new Headers();
  for (const name of ["accept", "content-type", "user-agent"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("authorization", `Bearer ${resolved.credential.accessToken}`);
  let upstream: Response;
  const upstreamStartedAt = performance.now();
  const headersTimeoutMs = remainingUpstreamHeadersTimeoutMs(
    upstreamHeaderDeadlineAt,
    runtime.now(),
    runtime.upstreamHeadersTimeoutMs,
  );
  if (headersTimeoutMs === null) {
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 503,
      outcome: "provider_unavailable",
      failureStage: "upstream_transport",
      attempts: resolved.attempts,
    });
    return apiError(
      "provider_unavailable",
      "The selected OpenCode provider could not be reached before the request deadline. Retry shortly.",
      503,
      true,
    );
  }
  try {
    upstream = await fetchWithHeadersTimeout(dependencies.fetch ?? fetch, target, {
      method: request.method,
      headers,
      body:
        request.method === "GET" || request.method === "HEAD"
          ? undefined
          : request.body,
      signal: request.signal,
      duplex: "half",
      cache: "no-store",
    } as RequestInit & { duplex: "half" }, headersTimeoutMs);
    recordCoderouterSpan({
      name: "upstream_attempt",
      startedAt: upstreamStartedAt,
      attributes: { provider: "opencode-go", attempt: 1, status: upstream.status },
    });
  } catch (error) {
    if (request.signal.aborted) throw error;
    recordCoderouterSpan({
      name: "upstream_attempt",
      startedAt: upstreamStartedAt,
      error: error instanceof Error ? error.name : "transport",
      attributes: { provider: "opencode-go", attempt: 1 },
    });
    reportCoderouterFailure("upstream_transport", error, {
      provider: "opencode-go",
      request_id: requestId,
    });
    captureOpenCodeHealth({
      requestId,
      identity: auth,
      startedAt,
      status: 502,
      outcome: "provider_unavailable",
      failureStage: "upstream_transport",
      attempts: resolved.attempts,
    });
    return apiError(
      "provider_unavailable",
      "The selected OpenCode provider could not be reached. Retry shortly.",
      502,
      true,
    );
  }
  addCoderouterBreadcrumb("request", "Model request completed", {
    provider: "opencode-go",
    status: upstream.status,
    duration_ms: Math.round(performance.now() - startedAt),
  });
  const streamed = isStreamingResponse(upstream);
  // Emit terminal health before the response body is consumed; token parsing
  // remains an independent aggregate-usage concern.
  captureOpenCodeHealth({
    requestId,
    identity: auth,
    startedAt,
    status: upstream.status,
    outcome: upstream.ok ? "success" : "upstream_error",
    failureStage: upstream.ok ? "none" : "upstream_response",
    attempts: resolved.attempts,
    responseStreamed: streamed,
  });
  const body = observeModelUsage(upstream.body, (usage) => {
    if (!usage || usage.totalTokens === 0) return;
    recordUsageEvent({
      requestId,
      teamId: auth.teamId,
      stackUserId: auth.stackUserId,
      vmId: auth.vmId,
      provider: "opencode-go",
      agent: "opencode",
      model: usage.model,
      inputTokens: usage.inputTokens,
      cachedInputTokens: usage.cachedInputTokens,
      outputTokens: usage.outputTokens,
      totalTokens: usage.totalTokens,
      status: upstream.status,
    });
  });
  return new Response(body, {
    status: upstream.status,
    headers: filteredResponseHeaders(upstream.headers),
  });
}

async function openCodeAccount(
  teamId: string,
  dependencies: Pick<OpenCodeDependencies, "select" | "credential"> = defaultDependencies,
  signal?: AbortSignal,
) {
  const attempted: string[] = [];
  for (let attempt = 0; attempt < 8; attempt++) {
    throwIfAborted(signal);
    const account = await dependencies.select(teamId, "opencode-go", attempted, signal);
    throwIfAborted(signal);
    if (!account) return null;
    attempted.push(account.id);
    try {
      const credential = await dependencies.credential({
        teamId,
        accountId: account.id,
        expectedRevision: account.vaultRevision,
        signal,
      });
      throwIfAborted(signal);
      if (credential.provider === "opencode-go") {
        return { account, credential, attempts: attempted.length };
      }
    } catch {
      throwIfAborted(signal);
      // Broken, refreshing, and transiently unavailable accounts are skipped.
    }
  }
  return null;
}

async function remoteConfig(
  accessToken: string,
  signal?: AbortSignal,
): Promise<Record<string, unknown>> {
  const response = await fetchProviderRead(() =>
    fetch(`${OPENCODE_CONSOLE}/api/config`, {
      headers: { authorization: `Bearer ${accessToken}` },
      cache: "no-store",
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(5_000)])
        : AbortSignal.timeout(5_000),
    }),
  );
  if (!response.ok)
    throw new Error(`OpenCode config failed: ${response.status}`);
  const value: unknown = await response.json();
  if (
    !isRecord(value) ||
    !isRecord(value.config) ||
    !isRecord(value.config.provider)
  ) {
    throw new Error("OpenCode returned an invalid provider catalog");
  }
  return value.config.provider;
}

function rewriteProviders(
  providers: Record<string, unknown>,
  routeToken: string,
  origin: string,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(providers).flatMap(([id, value]) => {
      if (!isRecord(value)) return [];
      const api = value.api;
      const npm =
        isRecord(api) && typeof api.package === "string"
          ? api.package
          : typeof value.npm === "string"
            ? value.npm
            : undefined;
      const models = isRecord(value.models)
        ? Object.fromEntries(
            Object.entries(value.models).map(([modelId, model]) => {
              if (!isRecord(model)) return [modelId, model];
              const nestedProvider = isRecord(model.provider)
                ? model.provider
                : undefined;
              return [
                modelId,
                {
                  ...model,
          ...(nestedProvider
            ? {
              provider: {
                ...publicNestedProvider(nestedProvider),
                api: `${origin}/api/coderouter/opencode/proxy/${encodeURIComponent(id)}`,
              },
                      }
                    : {}),
                },
              ];
            }),
          )
        : value.models;
      return [
        [
          id,
          {
            ...value,
            ...(npm ? { npm } : {}),
            api: undefined,
            models,
            options: {
              ...(isRecord(value.options) ? withoutSecrets(value.options) : {}),
              baseURL: `${origin}/api/coderouter/opencode/proxy/${encodeURIComponent(id)}`,
              apiKey: routeToken,
            },
          },
        ],
      ];
    }),
  );
}

function publicNestedProvider(
  value: Record<string, unknown>,
): Record<string, string> {
  const output: Record<string, string> = {};
  for (const key of ["id", "name", "npm"]) {
    const candidate = value[key];
    if (typeof candidate === "string" && candidate.length <= 512) {
      output[key] = candidate;
    }
  }
  return output;
}

function withoutSecrets(
  value: Record<string, unknown>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter(
      ([key]) =>
        !["apiKey", "token", "accessToken", "refreshToken", "headers"].includes(
          key,
        ),
    ),
  );
}

function captureAuthRejection(
  surface: "opencode_config" | "opencode_proxy",
  reason: RouteTokenAuthFailure,
): void {
  captureCoderouterEvent({
    event: "coderouter_auth_rejected",
    properties: { surface, reason },
  });
}

/** Per-VM attribution for bound tokens; omitted for unbound (CLI) tokens. */
function vmIdProperty(vmId: string | null): { vm_id?: string } {
  return vmId === null ? {} : { vm_id: vmId };
}

function captureOpenCodeHealth(input: {
  readonly requestId: string;
  readonly identity?: Pick<RouteTokenIdentity, "teamId" | "stackUserId" | "vmId">;
  readonly startedAt: number;
  readonly status: number;
  readonly outcome:
    | "success"
    | "upstream_error"
    | "no_usable_account"
    | "provider_unavailable"
    | "invalid_provider"
    | "unknown_provider"
    | "unauthorized";
  readonly failureStage:
    | "none"
    | "auth"
    | "account_selection"
    | "provider_config"
    | "upstream_transport"
    | "upstream_response";
  readonly attempts?: number;
  readonly responseStreamed?: boolean;
}): void {
  const durationMs = Math.round(performance.now() - input.startedAt);
  recordCoderouterOutcome({
    outcome: input.outcome,
    failureStage: input.failureStage,
    status: input.status,
    provider: "opencode-go",
    agent: "opencode",
    attempts: input.attempts ?? 0,
    refreshRetries: 0,
    responseStreamed: input.responseStreamed ?? false,
  });
  recordRouteEvent({
    requestId: input.requestId,
    teamId: input.identity?.teamId,
    stackUserId: input.identity?.stackUserId,
    vmId: input.identity?.vmId ?? null,
    provider: "opencode-go",
    agent: "opencode",
    outcome: input.outcome,
    failureStage: input.failureStage,
    status: input.status,
    attemptCount: input.attempts ?? 0,
    refreshRetryCount: 0,
    durationMs,
    responseStreamed: input.responseStreamed ?? false,
  });
}

function apiError(
  error: string,
  message: string,
  status: number,
  retryable: boolean,
): Response {
  return Response.json(
    { error, message, retryable },
    {
      status,
      headers: {
        "cache-control": "no-store",
        ...(retryable ? { "retry-after": "5" } : {}),
      },
    },
  );
}

type ProviderLookupAddress = { readonly address: string; readonly family: number };
type ProviderLookup = (hostname: string) => Promise<readonly ProviderLookupAddress[]>;

function safeProviderURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return false;
    return !unsafeProviderAddress(url.hostname);
  } catch {
    return false;
  }
}

async function resolveProviderURL(
  value: string,
  lookup: ProviderLookup = defaultProviderLookup,
): Promise<URL | null> {
  // Resolve every hostname before proxying it so private answers cannot pass
  // through the URL parser. The provider catalog is trusted, but this remains
  // defense-in-depth; the fetch implementation may perform a later lookup.
  if (!safeProviderURL(value)) return null;
  const url = new URL(value);
  const hostname = normalizeProviderHostname(url.hostname);
  if (isIP(hostname) !== 0) return url;
  try {
    const addresses = await lookup(hostname);
    if (addresses.length === 0 || addresses.some(({ address }) => unsafeProviderAddress(address))) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}

async function defaultProviderLookup(hostname: string): Promise<readonly ProviderLookupAddress[]> {
  return dnsLookup(hostname, { all: true, verbatim: true });
}

function normalizeProviderHostname(hostname: string): string {
  return hostname.replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
}

function unsafeProviderAddress(value: string): boolean {
  const address = normalizeProviderHostname(value);
  const family = isIP(address);
  if (family === 4) return unsafeIPv4Address(address);
  if (family !== 6) {
    return address === "localhost" || address === "localhost.localdomain";
  }

  const firstHextet = Number.parseInt(address.split(":", 1)[0] || "0", 16);
  if (
    address === "::" ||
    address === "::1" ||
    (firstHextet >= 0xfe80 && firstHextet <= 0xfebf) ||
    (firstHextet & 0xfe00) === 0xfc00 ||
    (firstHextet & 0xff00) === 0xff00
  ) {
    return true;
  }

  const mappedIPv4 = mappedIPv4Address(address);
  return mappedIPv4 !== null && unsafeIPv4Address(mappedIPv4);
}

function unsafeIPv4Address(value: string): boolean {
  const octets = value.split(".").map(Number);
  if (octets.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) {
    return false;
  }
  const [first, second] = octets;
  return (
    first === 0 ||
    first === 10 ||
    first === 127 ||
    (first === 100 && second >= 64 && second <= 127) ||
    (first === 169 && second === 254) ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) ||
    (first === 198 && (second === 18 || second === 19)) ||
    first >= 224
  );
}

function mappedIPv4Address(value: string): string | null {
  const prefix = "::ffff:";
  if (!value.startsWith(prefix)) return null;
  const groups = value.slice(prefix.length).split(":");
  if (groups.length !== 2) return null;
  const numbers = groups.map((group) => Number.parseInt(group, 16));
  if (numbers.some((number) => !Number.isInteger(number) || number < 0 || number > 0xffff)) {
    return null;
  }
  return [
    numbers[0] >> 8,
    numbers[0] & 0xff,
    numbers[1] >> 8,
    numbers[1] & 0xff,
  ].join(".");
}

function filteredResponseHeaders(input: Headers): Headers {
  const headers = new Headers({ "cache-control": "no-store" });
  for (const name of ["content-type", "x-request-id"]) {
    const value = input.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

function resolveOpenCodeRuntime(
  overrides: OpenCodeProxyRuntimeOverrides,
): OpenCodeProxyRuntime {
  return {
    now: overrides.now ?? (() => performance.now()),
    upstreamHeadersBudgetMs: overrides.upstreamHeadersBudgetMs ?? CODEROUTER_UPSTREAM_FAILOVER_BUDGET_MS,
    upstreamHeadersTimeoutMs: overrides.upstreamHeadersTimeoutMs ?? upstreamHeadersTimeoutMs(),
  };
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (!signal?.aborted) return;
  throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export const __test = {
  rewriteProviders,
  safeProviderURL,
  resolveProviderURL,
  openCodeAccount,
};
