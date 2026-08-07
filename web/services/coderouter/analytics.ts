import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";

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
  const properties = safeProperties(input.properties ?? {});
  if (input.teamId) {
    properties.$groups = { coderouter_team: input.teamId };
  }
  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    batch: [
      {
        event: input.event,
        distinct_id: input.userId,
        properties: {
          ...properties,
          $insert_id: randomUUID(),
          product: "coderouter",
          schema_version: 1,
        },
        timestamp: new Date().toISOString(),
      },
    ],
  });
  const task = deliver(body, dependencies.fetch).catch((error) => {
    reportCoderouterFailure("analytics_delivery", error);
  });
  dependencies.defer(task);
}

async function deliver(
  body: string,
  posthogFetch: typeof fetch,
): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await posthogFetch(`${POSTHOG_HOST}/batch/`, {
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
): Record<string, AnalyticsScalar | { coderouter_team: string }> {
  const output: Record<string, AnalyticsScalar | { coderouter_team: string }> =
    {};
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

export const __test = { safeProperties, deliver };
