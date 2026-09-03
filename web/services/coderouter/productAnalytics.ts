// CodeRouter product analytics in the main PostHog project, keyed by the
// Stack user id with the team as the `stack_team` group.
//
// This is the person-level view: who routes model traffic, through which
// agent and provider, how much, and how often it fails. It sits next to two
// other sinks with different jobs, and does not replace either:
//
// - `services/coderouter/analytics.ts` sends operations telemetry to the
//   isolated CodeRouter PostHog project with HMAC pseudonyms and no person
//   profiles. That project cannot answer "which users" by design.
// - `services/coderouter/usageLedger.ts` is the first-party ClickHouse
//   ledger behind customer-facing usage.
//
// Every property here is a closed enum, a bounded count or a sanitized model
// id. Prompts, outputs, credentials, headers and free-form errors never
// reach this module's inputs.
import {
  captureServerEvent,
  type ServerEventDependencies,
  type ServerEventInput,
  type ServerEventScalar,
} from "../analytics/serverEvents";
import {
  CODEROUTER_API_RATE_CARD_VERSION,
  estimateApiEquivalent,
} from "./apiEquivalentPricing";
import { __test as isolatedAnalytics } from "./analytics";

export const CODEROUTER_PRODUCT_SCHEMA_VERSION = 1;

/** PostHog's LLM analytics event; one per successful model completion with usage. */
export const CODEROUTER_GENERATION_EVENT = "$ai_generation";
export const CODEROUTER_REQUEST_FAILED_EVENT = "coderouter_request_failed";
export const CODEROUTER_ACCOUNT_ADDED_EVENT = "coderouter_account_added";
export const CODEROUTER_ACCOUNT_REMOVED_EVENT = "coderouter_account_removed";
export const CODEROUTER_SESSION_ISSUED_EVENT = "coderouter_route_session_issued";
export const CODEROUTER_CLAUDE_UPSTREAM_SET_EVENT = "coderouter_claude_upstream_set";
export const CODEROUTER_CLAUDE_UPSTREAM_REMOVED_EVENT = "coderouter_claude_upstream_removed";

export const CODEROUTER_PRODUCT_EVENT_NAMES = [
  CODEROUTER_GENERATION_EVENT,
  CODEROUTER_REQUEST_FAILED_EVENT,
  CODEROUTER_ACCOUNT_ADDED_EVENT,
  CODEROUTER_ACCOUNT_REMOVED_EVENT,
  CODEROUTER_SESSION_ISSUED_EVENT,
  CODEROUTER_CLAUDE_UPSTREAM_SET_EVENT,
  CODEROUTER_CLAUDE_UPSTREAM_REMOVED_EVENT,
] as const;

export type CoderouterRouteProvider = "codex" | "claude" | "opencode-go";
export type CoderouterAgent = "codex" | "claude" | "opencode" | "pi" | "other" | "unknown";

/** The authenticated route identity every proxied request carries. */
export type CoderouterIdentity = {
  readonly stackUserId: string;
  readonly teamId: string;
  /** Cloud VM row id when the route token is bound to a machine; null for CLI tokens. */
  readonly vmId?: string | null;
};

export type CoderouterGenerationInput = {
  readonly identity: CoderouterIdentity;
  readonly provider: CoderouterRouteProvider;
  readonly agent: string;
  readonly model: string | undefined;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly status: number;
  readonly durationMs?: number;
  readonly upstreamKind?: string;
  readonly responseStreamed?: boolean;
};

export type CoderouterRequestFailedInput = {
  readonly identity: CoderouterIdentity;
  readonly provider: CoderouterRouteProvider;
  readonly agent: string;
  readonly outcome: string;
  readonly failureStage: string;
  readonly status: number;
  readonly durationMs: number;
  readonly attemptCount?: number;
  readonly upstreamKind?: string;
};

export type CoderouterAccountInput = {
  readonly stackUserId: string;
  readonly teamId: string;
  /** Where the mutation came from: the native API or the legacy web dashboard. */
  readonly source: "native_api" | "legacy_dashboard";
};

const MAX_COUNT = 1_000_000_000_000;
const MODEL_ID = /^[A-Za-z0-9._:/-]{1,64}$/;

/** Build the `$ai_generation` event, or null when there is nothing to count. */
export function coderouterGenerationEvent(
  input: CoderouterGenerationInput,
  now: Date = new Date(),
): ServerEventInput | null {
  const inputTokens = safeCount(input.inputTokens);
  const cachedInputTokens = Math.min(inputTokens, safeCount(input.cachedInputTokens));
  const outputTokens = safeCount(input.outputTokens);
  const totalTokens = Math.max(inputTokens + outputTokens, safeCount(input.totalTokens));
  if (totalTokens === 0) return null;
  const modelFamily = isolatedAnalytics.analyticsModel(input.model);
  const estimate = estimateApiEquivalent({
    model: modelFamily,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens,
  });
  const properties: Record<string, ServerEventScalar | null | undefined> = {
    ...identityProperties(input.identity),
    // PostHog LLM analytics keys. `$ai_total_cost_usd` is the API-equivalent
    // list-price estimate of the tokens routed, not money cmux spent: the
    // upstream accounts are the user's own subscriptions.
    $ai_provider: aiProvider(input.provider),
    $ai_model: sanitizedModel(input.model),
    $ai_input_tokens: inputTokens,
    $ai_cache_read_input_tokens: cachedInputTokens,
    $ai_output_tokens: outputTokens,
    $ai_http_status: statusCode(input.status),
    $ai_is_error: false,
    ...(input.durationMs !== undefined ? { $ai_latency: Math.max(0, input.durationMs) / 1000 } : {}),
    ...(estimate.pricedTokens > 0 ? { $ai_total_cost_usd: estimate.usd } : {}),
    route_provider: input.provider,
    agent: agentValue(input.agent),
    model_family: modelFamily,
    total_tokens: totalTokens,
    api_equivalent_usd: estimate.usd,
    priced_tokens: estimate.pricedTokens,
    unpriced_tokens: estimate.unpricedTokens,
    pricing_version: CODEROUTER_API_RATE_CARD_VERSION,
    ...(input.upstreamKind ? { upstream_kind: upstreamKind(input.upstreamKind) } : {}),
    ...(input.responseStreamed !== undefined ? { response_streamed: input.responseStreamed } : {}),
  };
  return {
    event: CODEROUTER_GENERATION_EVENT,
    distinctId: input.identity.stackUserId,
    teamId: input.identity.teamId,
    properties,
    setOnce: { coderouter_first_generation_at: now.toISOString() },
    timestamp: now,
  };
}

/** Build the failed-request event. Successes are counted by `$ai_generation`. */
export function coderouterRequestFailedEvent(
  input: CoderouterRequestFailedInput,
  now: Date = new Date(),
): ServerEventInput {
  return {
    event: CODEROUTER_REQUEST_FAILED_EVENT,
    distinctId: input.identity.stackUserId,
    teamId: input.identity.teamId,
    properties: {
      ...identityProperties(input.identity),
      route_provider: input.provider,
      agent: agentValue(input.agent),
      outcome: token(input.outcome),
      failure_stage: token(input.failureStage),
      status: statusCode(input.status),
      duration_ms: Math.max(0, Math.round(input.durationMs)),
      attempt_count: Math.min(100, safeCount(input.attemptCount ?? 0)),
      ...(input.upstreamKind ? { upstream_kind: upstreamKind(input.upstreamKind) } : {}),
    },
    timestamp: now,
  };
}

export function coderouterAccountAddedEvent(
  input: CoderouterAccountInput & { readonly provider: string; readonly alreadyExists: boolean },
): ServerEventInput {
  return {
    event: CODEROUTER_ACCOUNT_ADDED_EVENT,
    distinctId: input.stackUserId,
    teamId: input.teamId,
    properties: {
      product: "coderouter",
      schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION,
      provider: token(input.provider),
      source: input.source,
      already_exists: input.alreadyExists,
    },
    setOnce: { coderouter_first_account_added_at: new Date().toISOString() },
  };
}

export function coderouterAccountRemovedEvent(
  input: CoderouterAccountInput & { readonly lastAccount?: boolean },
): ServerEventInput {
  return {
    event: CODEROUTER_ACCOUNT_REMOVED_EVENT,
    distinctId: input.stackUserId,
    teamId: input.teamId,
    properties: {
      product: "coderouter",
      schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION,
      source: input.source,
      ...(input.lastAccount !== undefined ? { last_account: input.lastAccount } : {}),
    },
  };
}

export function coderouterSessionIssuedEvent(
  input: { readonly stackUserId: string; readonly teamId: string },
): ServerEventInput {
  return {
    event: CODEROUTER_SESSION_ISSUED_EVENT,
    distinctId: input.stackUserId,
    teamId: input.teamId,
    properties: { product: "coderouter", schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION },
    setOnce: { coderouter_first_session_at: new Date().toISOString() },
  };
}

export function coderouterClaudeUpstreamEvent(
  input:
    | { readonly kind: "set"; readonly stackUserId: string; readonly teamId: string; readonly upstreamKind: string; readonly replaced: boolean }
    | { readonly kind: "removed"; readonly stackUserId: string; readonly teamId: string },
): ServerEventInput {
  return input.kind === "set"
    ? {
      event: CODEROUTER_CLAUDE_UPSTREAM_SET_EVENT,
      distinctId: input.stackUserId,
      teamId: input.teamId,
      properties: {
        product: "coderouter",
        schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION,
        upstream_kind: upstreamKind(input.upstreamKind),
        replaced: input.replaced,
      },
    }
    : {
      event: CODEROUTER_CLAUDE_UPSTREAM_REMOVED_EVENT,
      distinctId: input.stackUserId,
      teamId: input.teamId,
      properties: { product: "coderouter", schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION },
    };
}

/** Fire and forget. Never throws; delivery is deferred past the response. */
export function captureCoderouterProductEvent(
  event: ServerEventInput | null,
  dependencies: Partial<ServerEventDependencies> = {},
): void {
  if (!event) return;
  void captureServerEvent(event, dependencies);
}

function identityProperties(identity: CoderouterIdentity): Record<string, ServerEventScalar | undefined> {
  return {
    product: "coderouter",
    schema_version: CODEROUTER_PRODUCT_SCHEMA_VERSION,
    vm_bound: !!identity.vmId,
    vm_id: identity.vmId ?? undefined,
  };
}

function aiProvider(provider: CoderouterRouteProvider): string {
  switch (provider) {
    case "codex":
      return "openai";
    case "claude":
      return "anthropic";
    case "opencode-go":
      return "opencode";
  }
}

function sanitizedModel(model: string | undefined): string {
  const trimmed = model?.trim().toLowerCase();
  return trimmed && MODEL_ID.test(trimmed) ? trimmed : "unknown";
}

function agentValue(agent: string): CoderouterAgent {
  switch (agent) {
    case "codex":
    case "claude":
    case "opencode":
    case "pi":
    case "other":
      return agent;
    default:
      return "unknown";
  }
}

function upstreamKind(value: string): string {
  return value === "anthropic_api_key" || value === "anthropic_oauth" || value === "bedrock" ? value : "unknown";
}

function token(value: string): string {
  return /^[a-z0-9_-]{1,64}$/i.test(value) ? value : "unknown";
}

function statusCode(value: number): number {
  return Number.isInteger(value) && value >= 100 && value <= 599 ? value : 0;
}

function safeCount(value: number): number {
  return Number.isSafeInteger(value) && value >= 0 && value <= MAX_COUNT ? value : 0;
}
