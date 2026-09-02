import {
  authenticateRouteToken,
  markAccountCooldown,
  selectAccountForSession,
} from "./repository";
import { freshCredential } from "./refresh";
import { bearerToken, jsonError, rateLimitDelay } from "./codexProxy";
import { captureCoderouterEvent } from "./analytics";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import {
  observeModelUsage,
  reportStreamErrors,
  type ModelUsage,
} from "./responseUsage";
import { CLAUDE_OAUTH_BETA } from "./claudeOAuth";

const CLAUDE_UPSTREAM_ORIGIN = "https://api.anthropic.com";
// A fresh token that the provider still rejects means a revoked subscription
// or a provider-side block, not a burst: keep the account out of rotation long
// enough that it is not re-refreshed and re-rejected on every message.
const AUTH_REJECTED_COOLDOWN_MS = 15 * 60 * 1_000;
const ALLOWED_REQUEST_HEADERS = [
  "accept",
  "content-encoding",
  "content-type",
  "anthropic-version",
  "anthropic-beta",
  "user-agent",
] as const;
// Claude Code carries no session header; the stable per-session key lives in
// the body at metadata.user_id. Bodies at or under this size are parsed for
// it; larger requests fall back to non-sticky routing.
const SESSION_SCAN_LIMIT_BYTES = 20 * 1024 * 1024;

export type ClaudeMessagesTarget = "messages" | "count_tokens";

type ClaudeMessagesDependencies = {
  readonly authenticate: typeof authenticateRouteToken;
  readonly select: typeof selectAccountForSession;
  readonly credential: typeof freshCredential;
  readonly cooldown: typeof markAccountCooldown;
};

const STICKY_REFRESH_RETRIES = 4;
const STICKY_REFRESH_RETRY_DELAY_MS = 500;

/**
 * Same sticky-refresh patience as the Codex plane: a sticky session that
 * races an in-flight credential refresh waits for the winner instead of
 * moving accounts and discarding the provider's prompt cache.
 */
async function credentialWithStickyPatience(
  dependencies: Pick<ClaudeMessagesDependencies, "credential">,
  input: { teamId: string; accountId: string; expectedRevision: number },
  sticky: boolean,
): Promise<Awaited<ReturnType<ClaudeMessagesDependencies["credential"]>>> {
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

export function createClaudeMessagesProxy(
  dependencies: ClaudeMessagesDependencies,
): (request: Request, target?: ClaudeMessagesTarget) => Promise<Response> {
  return async (request, target = "messages") =>
    proxyClaudeRequestWith(dependencies, request, target);
}

export const proxyClaudeMessages = createClaudeMessagesProxy({
  authenticate: authenticateRouteToken,
  select: selectAccountForSession,
  credential: freshCredential,
  cooldown: markAccountCooldown,
});

/**
 * Extract the stable per-session key. Claude Code sends no dedicated session
 * header, but every /v1/messages body carries metadata.user_id, a value that
 * embeds the client session UUID and is constant across one session's turns.
 */
export function claudeSessionKey(
  headers: Headers,
  bodyBytes: ArrayBuffer,
): string | null {
  for (
    const name of [
      "x-claude-code-session-id",
      "x-claude-session-id",
      "anthropic-conversation-id",
      "session_id",
    ]
  ) {
    const value = headers.get(name)?.trim();
    if (value && value.length <= 512) return value;
  }
  if (bodyBytes.byteLength === 0 || bodyBytes.byteLength > SESSION_SCAN_LIMIT_BYTES) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bodyBytes));
    if (typeof parsed !== "object" || parsed === null) return null;
    const metadata = (parsed as { metadata?: unknown }).metadata;
    if (typeof metadata !== "object" || metadata === null) return null;
    const userId = (metadata as { user_id?: unknown }).user_id;
    return typeof userId === "string" && userId.length > 0 && userId.length <= 512
      ? userId
      : null;
  } catch {
    return null;
  }
}

function upstreamUrl(target: ClaudeMessagesTarget, requestUrl: string): URL {
  const url = new URL(
    target === "count_tokens" ? "/v1/messages/count_tokens" : "/v1/messages",
    CLAUDE_UPSTREAM_ORIGIN,
  );
  url.search = new URL(requestUrl).search;
  return url;
}

async function proxyClaudeRequestWith(
  dependencies: ClaudeMessagesDependencies,
  request: Request,
  target: ClaudeMessagesTarget,
): Promise<Response> {
  const startedAt = performance.now();
  const token = bearerToken(request);
  if (!token) {
    addCoderouterBreadcrumb("auth", "Route token missing", {}, "warning");
    captureCoderouterEvent({
      event: "coderouter_auth_rejected",
      properties: { surface: "messages", reason: "missing_route_token" },
    });
    captureRouteHealth({
      request,
      startedAt,
      status: 401,
      attempted: 0,
      refreshRetries: 0,
      outcome: "unauthorized",
      failureStage: "auth",
      responseStreamed: false,
    });
    return jsonError(
      "unauthorized",
      401,
      undefined,
      "This machine has no model-plane credential. Recreate it from cmux to mint a fresh one.",
      false,
    );
  }
  const identity = await dependencies.authenticate(token);
  if (!identity) {
    addCoderouterBreadcrumb("auth", "Route token rejected", {}, "warning");
    captureCoderouterEvent({
      event: "coderouter_auth_rejected",
      properties: { surface: "messages", reason: "invalid_route_token" },
    });
    captureRouteHealth({
      request,
      startedAt,
      status: 401,
      attempted: 0,
      refreshRetries: 0,
      outcome: "unauthorized",
      failureStage: "auth",
      responseStreamed: false,
    });
    return jsonError(
      "unauthorized",
      401,
      undefined,
      "This machine's model-plane credential expired or was revoked. Recreate the machine from cmux to mint a fresh one.",
      false,
    );
  }
  addCoderouterBreadcrumb("auth", "Route token accepted", { path: target });

  const forwardedHeaders = new Headers();
  for (const name of ALLOWED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) forwardedHeaders.set(name, value);
  }
  // One buffered copy of the body serves every retry attempt (the Codex plane
  // pays the same cost through request.clone()).
  const bodyBytes = await request.arrayBuffer();
  const sessionKey = claudeSessionKey(request.headers, bodyBytes);
  const attempted: string[] = [];
  let refreshRetries = 0;
  let failureStage:
    | "account_selection"
    | "credential_refresh"
    | "upstream_transport" = "account_selection";
  let upstream: Response | null = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    const account = await dependencies.select({
      teamId: identity.teamId,
      provider: "claude",
      sessionKey,
      excludedAccountIds: attempted,
    });
    if (!account) break;
    attempted.push(account.id);
    addCoderouterBreadcrumb("routing", "Selected provider account", {
      provider: "claude",
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
    if (credential.provider !== "claude") continue;
    try {
      upstream = await sendClaude(target, request, forwardedHeaders, bodyBytes, credential);
    } catch (error) {
      // A caller that hung up gets no retries on its dime.
      if (request.signal.aborted) throw error;
      failureStage = "upstream_transport";
      reportCoderouterFailure("upstream_transport", error, {
        provider: "claude",
        attempt: attempt + 1,
      });
      continue;
    }
    if (upstream.status === 401) {
      refreshRetries++;
      // The rejected response is never handed to the caller: drop its body
      // and forget it so an exhausted pool answers no_usable_account, not a
      // dead stream.
      await discardBody(upstream);
      upstream = null;
      addCoderouterBreadcrumb(
        "refresh",
        "Refreshing rejected credential",
        {
          provider: "claude",
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
        if (refreshed.provider !== "claude") continue;
        upstream = await sendClaude(
          target,
          request,
          forwardedHeaders,
          bodyBytes,
          refreshed,
        );
      } catch (error) {
        failureStage = "credential_refresh";
        reportCoderouterFailure("provider_refresh", error, {
          provider: "claude",
          forced: true,
        });
        continue;
      }
      // Still rejected with a fresh token: this account is unusable right now
      // (revoked subscription, provider-side block). Park it as an auth
      // failure and let a healthy sibling take the session instead of
      // surfacing its 401.
      if (upstream.status === 401) {
        await discardBody(upstream);
        upstream = null;
        reportCoderouterFailure("provider_refresh", new Error("credential rejected after refresh"), {
          provider: "claude",
          status: 401,
        });
        await dependencies.cooldown(account.id, AUTH_REJECTED_COOLDOWN_MS, "auth_rejected");
        continue;
      }
    }
    // 429: this account is out of quota; 529: Anthropic is overloaded for it.
    // Either way, cool the account down and let another one take the session.
    if (upstream.status === 429 || upstream.status === 529) {
      const limited = upstream;
      await discardBody(limited);
      upstream = null;
      reportCoderouterFailure(
        "provider_rate_limit",
        new Error("rate limited"),
        {
          provider: "claude",
          status: limited.status,
        },
      );
      await dependencies.cooldown(account.id, rateLimitDelay(limited.headers));
      continue;
    }
    break;
  }
  if (!upstream) {
    captureRouteHealth({
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
      "No healthy Claude subscription is currently available for this team. Add one in cmux or retry shortly.",
      true,
    );
  }
  const responseHeaders = new Headers();
  for (const name of [
    "content-type",
    "request-id",
    "retry-after",
    "anthropic-ratelimit-requests-limit",
    "anthropic-ratelimit-requests-remaining",
    "anthropic-ratelimit-requests-reset",
    "anthropic-ratelimit-tokens-limit",
    "anthropic-ratelimit-tokens-remaining",
    "anthropic-ratelimit-tokens-reset",
  ]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }
  if (!responseHeaders.has("content-type")) {
    responseHeaders.set("content-type", "application/json; charset=utf-8");
  }
  responseHeaders.set("cache-control", "no-store");
  const status = upstream.status;
  captureRouteHealth({
    identity,
    request,
    startedAt,
    status,
    attempted: attempted.length,
    refreshRetries,
    outcome: status >= 200 && status < 300 ? "success" : "upstream_error",
    responseStreamed: upstream.body !== null,
  });
  const onStreamError = (error: unknown) =>
    reportCoderouterFailure("upstream_transport", error, {
      provider: "claude",
      stage: "response_stream",
      target,
    });
  if (target === "count_tokens") {
    return new Response(
      upstream.body ? reportStreamErrors(upstream.body, onStreamError) : null,
      { status, headers: responseHeaders },
    );
  }
  const observedBody = observeModelUsage(
    upstream.body,
    (usage) => captureModelUsage(identity.teamId, usage),
    onStreamError,
  );
  return new Response(observedBody, { status, headers: responseHeaders });
}

/**
 * A response the loop is about to retry past must not keep its upstream
 * stream (and connection) alive behind the next attempt.
 */
async function discardBody(response: Response): Promise<void> {
  await response.body?.cancel().catch(() => undefined);
}

async function sendClaude(
  target: ClaudeMessagesTarget,
  request: Request,
  forwardedHeaders: Headers,
  bodyBytes: ArrayBuffer,
  credential: { accessToken: string },
): Promise<Response> {
  const headers = new Headers(forwardedHeaders);
  headers.set("authorization", `Bearer ${credential.accessToken}`);
  // The client's own credential header must never reach the provider; the
  // OAuth beta capability must always be present alongside the bearer token.
  headers.delete("x-api-key");
  ensureCommaHeaderValue(headers, "anthropic-beta", CLAUDE_OAUTH_BETA);
  // The caller's abort propagates upstream so a disconnected machine does not
  // keep a provider request streaming to nobody.
  return await fetch(upstreamUrl(target, request.url), {
    method: "POST",
    headers,
    body: bodyBytes,
    cache: "no-store",
    signal: request.signal,
  });
}

function ensureCommaHeaderValue(headers: Headers, name: string, value: string): void {
  const existing = headers.get(name);
  if (!existing) {
    headers.set(name, value);
    return;
  }
  if (existing.split(",").some((part) => part.trim() === value)) return;
  headers.set(name, `${existing},${value}`);
}

function captureRouteHealth(input: {
  readonly identity?: { readonly teamId: string; readonly stackUserId: string };
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
      provider: "claude",
      status: input.status,
      outcome: input.outcome,
      attempts: input.attempted,
      duration_ms: durationMs,
    },
    input.status >= 500 ? "error" : input.status >= 400 ? "warning" : "info",
  );
  captureCoderouterEvent({
    event: "coderouter_route_health",
    teamId: input.identity?.teamId,
    properties: {
      provider: "claude",
      agent,
      outcome: input.outcome,
      failure_stage: input.outcome === "success"
        ? "none"
        : input.outcome === "unauthorized"
        ? "auth"
        : input.outcome === "no_usable_account"
        ? input.failureStage ?? "account_selection"
        : "upstream_response",
      status: input.status,
      attempt_count: input.attempted,
      refresh_retry_count: input.refreshRetries,
      duration_ms: durationMs,
      response_streamed: input.responseStreamed,
    },
  });
}

function captureModelUsage(teamId: string, usage: ModelUsage | null): void {
  if (!usage || usage.totalTokens === 0) return;
  captureCoderouterEvent({
    event: "coderouter_model_request_completed",
    teamId,
    properties: {
      provider: "claude",
      model: usage.model ?? "unknown",
      // Anthropic reports cache reads and cache writes outside input_tokens;
      // fold both back in so cached ⊆ input holds like it does for the
      // OpenAI-shaped planes and no prompt token goes uncounted.
      input_tokens: usage.inputTokens + usage.cachedInputTokens +
        usage.cacheCreationInputTokens,
      cached_input_tokens: usage.cachedInputTokens,
      cache_creation_input_tokens: usage.cacheCreationInputTokens,
      output_tokens: usage.outputTokens,
      total_tokens: usage.totalTokens + usage.cachedInputTokens +
        usage.cacheCreationInputTokens,
    },
  });
}

function agentFromUserAgent(value: string | null): string {
  const normalized = value?.toLowerCase() ?? "";
  if (normalized.includes("claude-cli") || normalized.includes("claude-code")) {
    return "claude";
  }
  return "other";
}
