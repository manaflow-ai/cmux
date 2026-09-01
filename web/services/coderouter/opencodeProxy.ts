import { authenticateRouteToken, listAccounts, selectAccountForRequest } from "./repository";
import {
  CLAUDE_PLANE_PROVIDERS,
  CODEX_PLANE_PROVIDERS,
  type CodeRouterAccountSummary,
  type CodeRouterProvider,
} from "./types";
import { freshCredential } from "./refresh";
import { fetchProviderRead } from "./providerFetch";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import { observeModelUsage } from "./responseUsage";

const OPENCODE_CONSOLE = "https://console.opencode.ai";

type OpenCodeConfigDependencies = {
  readonly identity: typeof routeIdentity;
  readonly accounts: typeof listAccounts;
  readonly opencodeAccount: typeof openCodeAccount;
  readonly remote: typeof remoteConfig;
};

/**
 * The opencode config a machine fetches on first shell. Every provider entry
 * points at this deployment: the team's OpenCode Go catalog (if it has one)
 * rides the opencode proxy, and the Claude and Codex planes are published as
 * opencode's own `anthropic` and `openai` providers whenever the team has an
 * account of a kind those planes route over — so opencode works off the same
 * connected accounts as `claude` and `codex`, with no OpenCode subscription.
 */
export function createOpenCodeClientConfig(
  dependencies: OpenCodeConfigDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const auth = await dependencies.identity(request);
    if (!auth) {
      captureAuthRejection(request, "opencode_config");
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    // The proxy origin comes from the serving request, not a hardcoded host,
    // so the config works on every deployment of this app (coderouter.dev,
    // the cmux origin Cloud VMs are minted against, previews, self-hosted).
    const origin = new URL(request.url).origin;
    // The config is written once on the machine's first shell, so an account
    // mid-refresh (usable again in seconds) still counts here.
    const kinds = activeProviderKinds(await dependencies.accounts(auth.teamId), {
      includeRefreshing: true,
    });
    let provider: Record<string, unknown> = {};
    let catalogUnavailable = false;
    if (kinds.has("opencode-go")) {
      const resolved = await dependencies.opencodeAccount(auth.teamId);
      if (resolved) {
        try {
          provider = rewriteProviders(
            await dependencies.remote(resolved.credential.accessToken),
            auth.token,
            origin,
          );
        } catch (error) {
          // The OpenCode catalog is one provider among several now; a console
          // outage must not take the Claude/Codex planes down with it.
          reportCoderouterFailure("provider_usage", error, { provider: "opencode-go" });
          catalogUnavailable = true;
        }
      } else {
        catalogUnavailable = true;
      }
    }
    provider = { ...provider, ...planeProviders(kinds, auth.token, origin) };
    if (Object.keys(provider).length === 0) {
      // A team with an OpenCode account whose catalog could not be fetched is
      // not a team without accounts: the machine retries next shell either
      // way, but only the latter should send anyone off to connect one.
      return Response.json(
        { error: catalogUnavailable ? "provider_unavailable" : "no_usable_account" },
        { status: 503 },
      );
    }
    return Response.json(
      { provider },
      {
        headers: { "cache-control": "no-store" },
      },
    );
  };
}

export const openCodeClientConfig = createOpenCodeClientConfig({
  identity: routeIdentity,
  accounts: listAccounts,
  opencodeAccount: openCodeAccount,
  remote: remoteConfig,
});

/**
 * The kinds of account a new session could be placed on right now: active
 * and not cooling down — the same gate `claimAccountForPlacement` applies.
 * `includeRefreshing` also counts accounts mid-refresh (seconds from usable),
 * for callers whose answer is written down once rather than re-asked.
 */
export function activeProviderKinds(
  accounts: readonly CodeRouterAccountSummary[],
  options: { readonly includeRefreshing?: boolean } = {},
): ReadonlySet<CodeRouterProvider> {
  return new Set(claimableAccounts(accounts, options).map((account) => account.provider));
}

export function claimableAccounts(
  accounts: readonly CodeRouterAccountSummary[],
  options: { readonly includeRefreshing?: boolean } = {},
): readonly CodeRouterAccountSummary[] {
  const now = Date.now();
  return accounts.filter((account) =>
    (account.state === "active" ||
      (options.includeRefreshing === true && account.state === "refreshing")) &&
    (!account.cooldownUntil || Date.parse(account.cooldownUntil) <= now),
  );
}

/**
 * opencode provider entries for the planes this deployment serves. Model
 * catalogs come from opencode's own registry for these well-known ids; only
 * the endpoint and key are ours. The Anthropic SDK sends the key as
 * x-api-key and the OpenAI SDK as a bearer; the planes accept the route
 * token either way.
 */
export function planeProviders(
  kinds: ReadonlySet<CodeRouterProvider>,
  routeToken: string,
  origin: string,
): Record<string, unknown> {
  const entries: [string, unknown][] = [];
  if (CLAUDE_PLANE_PROVIDERS.some((kind) => kinds.has(kind))) {
    entries.push(["anthropic", { options: { baseURL: `${origin}/v1`, apiKey: routeToken } }]);
  }
  if (CODEX_PLANE_PROVIDERS.some((kind) => kinds.has(kind))) {
    entries.push(["openai", { options: { baseURL: `${origin}/v1`, apiKey: routeToken } }]);
  }
  return Object.fromEntries(entries);
}

export async function proxyOpenCodeRequest(
  request: Request,
  providerId: string,
  path: readonly string[],
): Promise<Response> {
  const startedAt = performance.now();
  const auth = await routeIdentity(request);
  if (!auth) {
    captureAuthRejection(request, "opencode_proxy");
    captureOpenCodeHealth({
      startedAt,
      status: 401,
      outcome: "unauthorized",
      failureStage: "auth",
    });
    return apiError(
      "unauthorized",
      "Your coderouter session expired or was revoked. Run `cr login` and retry.",
      401,
      false,
    );
  }
  const resolved = await openCodeAccount(auth.teamId);
  if (!resolved) {
    captureOpenCodeHealth({
      teamId: auth.teamId,
      startedAt,
      status: 503,
      outcome: "no_usable_account",
      failureStage: "account_selection",
    });
    return apiError(
      "no_usable_account",
      "No OpenCode Go account is connected for your team right now. Add one with `cr add opencode`, or connect a Claude or Codex account on your Mac (`cmux ai-accounts upload claude` or `cmux ai-accounts upload codex`) and opencode routes over it.",
      503,
      true,
    );
  }
  let config: Record<string, unknown>;
  try {
    config = await remoteConfig(resolved.credential.accessToken);
  } catch (error) {
    reportCoderouterFailure("provider_usage", error, {
      provider: "opencode-go",
      operation: "config",
    });
    captureOpenCodeHealth({
      teamId: auth.teamId,
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
      teamId: auth.teamId,
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
      teamId: auth.teamId,
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
  const target = new URL(base);
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
  try {
    upstream = await fetch(target, {
      method: request.method,
      headers,
      body:
        request.method === "GET" || request.method === "HEAD"
          ? undefined
          : request.body,
      duplex: "half",
      cache: "no-store",
    } as RequestInit & { duplex: "half" });
  } catch (error) {
    reportCoderouterFailure("upstream_transport", error, {
      provider: "opencode-go",
    });
    captureOpenCodeHealth({
      teamId: auth.teamId,
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
  // Emit terminal health before the response body is consumed; token parsing
  // remains an independent aggregate-usage concern.
  captureOpenCodeHealth({
    teamId: auth.teamId,
    startedAt,
    status: upstream.status,
    outcome: upstream.ok ? "success" : "upstream_error",
    failureStage: upstream.ok ? "none" : "upstream_response",
    attempts: resolved.attempts,
    responseStreamed: upstream.body !== null,
  });
  const body = observeModelUsage(upstream.body, (usage) => {
    if (!usage || usage.totalTokens === 0) return;
    captureCoderouterEvent({
      event: "coderouter_model_request_completed",
      teamId: auth.teamId,
      properties: {
        provider: "opencode-go",
        model: usage.model ?? "unknown",
        input_tokens: usage.inputTokens,
        cached_input_tokens: usage.cachedInputTokens,
        output_tokens: usage.outputTokens,
        total_tokens: usage.totalTokens,
      },
    });
  });
  return new Response(body, {
    status: upstream.status,
    headers: filteredResponseHeaders(upstream.headers),
  });
}

async function openCodeAccount(
  teamId: string,
  dependencies = {
    select: selectAccountForRequest,
    credential: freshCredential,
  },
) {
  const attempted: string[] = [];
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await dependencies.select(teamId, "opencode-go", attempted);
    if (!account) return null;
    attempted.push(account.id);
    try {
      const credential = await dependencies.credential({
        teamId,
        accountId: account.id,
        expectedRevision: account.vaultRevision,
      });
      if (credential.provider === "opencode-go") {
        return { account, credential, attempts: attempted.length };
      }
    } catch {
      // Broken, refreshing, and transiently unavailable accounts are skipped.
    }
  }
  return null;
}

async function remoteConfig(
  accessToken: string,
): Promise<Record<string, unknown>> {
  const response = await fetchProviderRead(() =>
    fetch(`${OPENCODE_CONSOLE}/api/config`, {
      headers: { authorization: `Bearer ${accessToken}` },
      cache: "no-store",
      signal: AbortSignal.timeout(5_000),
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

async function routeIdentity(
  request: Request,
): Promise<{ teamId: string; stackUserId: string; token: string } | null> {
  const header = request.headers.get("authorization")?.trim() ?? "";
  const token = /^Bearer[ \t]+(.+)$/i.exec(header)?.[1]?.trim();
  if (!token) return null;
  const identity = await authenticateRouteToken(token);
  return identity ? { ...identity, token } : null;
}

function captureAuthRejection(
  request: Request,
  surface: "opencode_config" | "opencode_proxy",
): void {
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  captureCoderouterEvent({
    event: "coderouter_auth_rejected",
    properties: {
      surface,
      reason: /^Bearer[ \t]+(.+)$/i.test(authorization)
        ? "invalid_route_token"
        : "missing_route_token",
    },
  });
}

function captureOpenCodeHealth(input: {
  readonly teamId?: string;
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
  captureCoderouterEvent({
    event: "coderouter_route_health",
    ...(input.teamId ? { teamId: input.teamId } : {}),
    properties: {
      provider: "opencode-go",
      agent: "opencode",
      outcome: input.outcome,
      failure_stage: input.failureStage,
      status: input.status,
      duration_ms: Math.round(performance.now() - input.startedAt),
      attempt_count: input.attempts ?? 0,
      refresh_retry_count: 0,
      response_streamed: input.responseStreamed ?? false,
    },
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

function safeProviderURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return false;
    const hostname = url.hostname.toLowerCase();
    return (
      hostname !== "localhost" &&
      hostname !== "0.0.0.0" &&
      hostname !== "::1" &&
      !/^127\./.test(hostname) &&
      !/^10\./.test(hostname) &&
      !/^192\.168\./.test(hostname) &&
      !/^172\.(1[6-9]|2[0-9]|3[01])\./.test(hostname)
    );
  } catch {
    return false;
  }
}

function filteredResponseHeaders(input: Headers): Headers {
  const headers = new Headers({ "cache-control": "no-store" });
  for (const name of ["content-type", "x-request-id"]) {
    const value = input.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export const __test = { rewriteProviders, safeProviderURL, openCodeAccount, routeIdentity };
