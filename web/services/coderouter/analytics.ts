import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";
import { coderouterTeamAnalyticsId } from "./analyticsIdentity";
import {
  CODEROUTER_API_RATE_CARD_VERSION,
  estimateApiEquivalent,
} from "./apiEquivalentPricing";

export type CoderouterAnalyticsEvent =
  | "coderouter_account_added"
  | "coderouter_account_removed"
  | "coderouter_account_status_viewed"
  | "coderouter_auth_rejected"
  | "coderouter_route_session_issued"
  | "coderouter_route_session_revoked"
  | "coderouter_model_request_completed";

type AnalyticsScalar = string | number | boolean;

type CaptureInput = {
  readonly event: CoderouterAnalyticsEvent;
  readonly userId: string;
  readonly teamId?: string;
  readonly properties?: Readonly<
    Record<string, AnalyticsScalar | null | undefined>
  >;
};

type AnalyticsDependencies = {
  readonly fetch: typeof fetch;
  readonly defer: (task: Promise<unknown>) => void;
  readonly enabled: () => boolean;
  readonly usageConfig: () => CoderouterUsageAnalyticsConfig | null;
};

type CoderouterUsageAnalyticsConfig = {
  readonly ingestHost: string;
  readonly projectKey: string;
  readonly scopeSecret: string;
};

const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);
const SENSITIVE_PROPERTY =
  /account.?id|authorization|body|content|cookie|credential|email|header|key|prompt|response|secret|session|token/i;
const CAPTURE_TIMEOUT_MS = 2_000;

const defaultDependencies: AnalyticsDependencies = {
  fetch,
  defer: (task) => {
    try {
      after(task);
    } catch {
      // Unit tests and non-request scripts do not have a Next request scope.
      // The promise is already running; always absorb rejection.
      void task.catch(() => undefined);
    }
  },
  enabled: () =>
    process.env.VERCEL_ENV === "production" ||
    process.env.CODEROUTER_ANALYTICS_FORCE === "1",
  usageConfig: coderouterUsageAnalyticsConfig,
};

/**
 * Best-effort product analytics. It never blocks the response and accepts only
 * an intentionally small scalar property surface. Prompts, output, provider
 * account IDs, credentials, route tokens, headers, and email are rejected.
 */
export function captureCoderouterEvent(
  input: CaptureInput,
  dependencies: AnalyticsDependencies = defaultDependencies,
): void {
  if (!dependencies.enabled()) return;
  const aggregateUsage =
    input.event === "coderouter_model_request_completed";
  // Usage is deliberately team-scoped and never attributable to an
  // individual. A malformed call without a team is dropped rather than
  // falling back to the Stack user identity.
  if (aggregateUsage && !input.teamId) return;
  const usageConfig = aggregateUsage ? dependencies.usageConfig() : null;
  // Usage must never fall back to the general cmux PostHog project or an
  // unkeyed identifier when the isolated CodeRouter configuration is absent.
  if (aggregateUsage && !usageConfig) return;
  const teamScope = aggregateUsage
    ? coderouterTeamAnalyticsId(input.teamId!, usageConfig!.scopeSecret)
    : null;
  const properties = aggregateUsage
    ? aiUsageProperties(input.properties ?? {}, teamScope!)
    : safeProperties(input.properties ?? {});
  if (!properties) return;
  const body = JSON.stringify({
    api_key: usageConfig?.projectKey ?? POSTHOG_PROJECT_KEY,
    batch: [
      {
        event: aggregateUsage ? "$ai_generation" : input.event,
        distinct_id: aggregateUsage
          ? teamScope
          : input.userId,
        properties: {
          ...properties,
          $insert_id: randomUUID(),
          product: "coderouter",
          schema_version: aggregateUsage ? 2 : 1,
        },
        timestamp: new Date().toISOString(),
      },
    ],
  });
  const task = deliver(
    body,
    dependencies.fetch,
    usageConfig?.ingestHost ?? POSTHOG_HOST,
  ).catch((error) => {
    reportCoderouterFailure("analytics_delivery", error);
  });
  dependencies.defer(task);
}

async function deliver(
  body: string,
  posthogFetch: typeof fetch,
  posthogHost = POSTHOG_HOST,
): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await posthogFetch(`${posthogHost}/batch/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(CAPTURE_TIMEOUT_MS),
      });
      if (response.ok) {
        addCoderouterBreadcrumb("analytics", "PostHog event accepted", {
          attempt: attempt + 1,
        });
        return;
      }
      if (!RETRYABLE_STATUS.has(response.status) || attempt === 1) {
        throw new Error(
          `PostHog capture failed with status ${response.status}`,
        );
      }
    } catch (error) {
      if (attempt === 1) throw error;
    }
  }
}

function safeProperties(
  input: Readonly<Record<string, AnalyticsScalar | null | undefined>>,
): Record<string, AnalyticsScalar> {
  const output: Record<string, AnalyticsScalar> = {};
  for (const [key, value] of Object.entries(input)) {
    const safeTokenCount = /^(?:input|cached_input|output|total)_tokens$/.test(
      key,
    );
    if (SENSITIVE_PROPERTY.test(key) && !safeTokenCount) continue;
    if (
      typeof value === "string" ||
      typeof value === "number" ||
      typeof value === "boolean"
    ) {
      output[key] = value;
    }
  }
  return output;
}

function aiUsageProperties(
  input: Readonly<Record<string, AnalyticsScalar | null | undefined>>,
  teamScope: string,
): Record<string, AnalyticsScalar> | null {
  const model = safeDimension(input.model);
  const provider = aiProvider(input.provider);
  const inputTokens = safeCount(input.input_tokens);
  const cachedInputTokens = Math.min(
    inputTokens,
    safeCount(input.cached_input_tokens),
  );
  const outputTokens = safeCount(input.output_tokens);
  const totalTokens = Math.max(
    inputTokens + outputTokens,
    safeCount(input.total_tokens),
  );
  if (totalTokens === 0) return null;
  const estimate = estimateApiEquivalent({
    model,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens,
  });
  return {
    $process_person_profile: false,
    $ai_model: model,
    $ai_provider: provider,
    $ai_input_tokens: inputTokens,
    $ai_cache_read_input_tokens: cachedInputTokens,
    $ai_cache_reporting_exclusive: false,
    $ai_output_tokens: outputTokens,
    ...(estimate.pricedTokens > 0
      ? { $ai_total_cost_usd: estimate.usd }
      : {}),
    coderouter_total_tokens: totalTokens,
    coderouter_priced_tokens: estimate.pricedTokens,
    coderouter_unpriced_tokens: estimate.unpricedTokens,
    coderouter_pricing_version: CODEROUTER_API_RATE_CARD_VERSION,
    coderouter_team_scope: teamScope,
  };
}

function safeCount(value: AnalyticsScalar | null | undefined): number {
  return typeof value === "number" &&
      Number.isSafeInteger(value) &&
      value >= 0
    ? value
    : 0;
}

function safeDimension(value: AnalyticsScalar | null | undefined): string {
  if (typeof value !== "string") return "unknown";
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 &&
      normalized.length <= 128 &&
      /^[a-z0-9][a-z0-9._:/-]*$/.test(normalized)
    ? normalized
    : "unknown";
}

function aiProvider(value: AnalyticsScalar | null | undefined): string {
  switch (value) {
    case "codex":
    case "openai":
    case "openai-apikey":
      return "openai";
    case "claude":
    case "anthropic":
    case "anthropic-apikey":
      return "anthropic";
    default:
      return "unknown";
  }
}

function coderouterUsageAnalyticsConfig():
  | CoderouterUsageAnalyticsConfig
  | null {
  const projectKey = process.env.POSTHOG_CODEROUTER_PROJECT_KEY?.trim();
  const scopeSecret =
    process.env.CODEROUTER_ANALYTICS_SCOPE_SECRET?.trim();
  if (!projectKey || !scopeSecret || scopeSecret.length < 32) return null;
  return {
    projectKey,
    scopeSecret,
    ingestHost: (
      process.env.POSTHOG_CODEROUTER_INGEST_HOST ??
      "https://us.i.posthog.com"
    ).replace(/\/$/, ""),
  };
}

export const __test = { safeProperties, aiUsageProperties, deliver };
