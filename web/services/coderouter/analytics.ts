import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import {
  addCoderouterBreadcrumb,
  reportCoderouterFailure,
} from "./observability";

// Coderouter analytics live in the main cmux PostHog project, keyed by the
// Stack user id the cmux apps identify with, so one person's app activity and
// their coderouter requests are the same person in PostHog. Team and VM ids
// are opaque server-minted identifiers and travel as properties. What never
// travels: prompts, outputs, headers, credentials, emails, account labels;
// every event is rebuilt from a closed schema. (Until 2026-09-03 these events
// went to a separate project under HMAC pseudonyms, which made that join
// impossible. Token and request usage belongs exclusively in ClickHouse.)

export type CoderouterAnalyticsEvent =
  | "coderouter_account_added"
  | "coderouter_account_removed"
  | "coderouter_account_status_viewed"
  | "coderouter_auth_rejected"
  | "coderouter_route_session_issued"
  | "coderouter_route_session_revoked"
  | "coderouter_organization_catalog_viewed"
  | "coderouter_metrics_loaded"
  | "coderouter_vm_usage_viewed"
  | "coderouter_cli_command_started"
  | "coderouter_cli_command_completed"
  | "coderouter_claude_upstream_set"
  | "coderouter_claude_upstream_removed"
  /** @deprecated usage is ClickHouse-only; this event is rejected. */
  | "coderouter_model_request_completed";

type AnalyticsScalar = string | number | boolean;
export type CoderouterRawProperty = AnalyticsScalar | readonly Record<string, unknown>[];

type CaptureInput = {
  readonly event: CoderouterAnalyticsEvent;
  /** Stack user id: the PostHog person. Absent for unauthenticated events. */
  readonly userId?: string;
  /** Opaque team id, sent as `team_id`. */
  readonly teamId?: string;
  readonly properties?: Readonly<
    Record<string, AnalyticsScalar | null | undefined>
  >;
};

type AnalyticsDependencies = {
  readonly fetch: typeof fetch;
  readonly defer: (task: Promise<unknown>) => void;
  readonly enabled: () => boolean;
  readonly config: () => CoderouterAnalyticsConfig | null;
};

export type CoderouterAnalyticsConfig = {
  readonly ingestHost: string;
  readonly projectKey: string;
};

/** Identity for events with no authenticated user (auth rejects, alerts). */
const SERVER_DISTINCT_ID = "coderouter-server";

const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);
const CAPTURE_TIMEOUT_MS = 2_000;
const MAX_COUNT = 1_000_000_000_000;
const ANALYTICS_SCHEMA_VERSION = 3;
const ANALYTICS_SERVICE_VERSION = "coderouter-web-v1";

/**
 * Runs a best-effort telemetry task after the response is sent. Shared by the
 * PostHog capture and the ClickHouse usage ledger so both leave the request
 * path the same way.
 */
export function deferCoderouterTask(task: Promise<unknown>): void {
  try {
    after(task);
  } catch {
    // Unit tests and non-request scripts do not have a Next request scope.
    // The promise is already running; always absorb rejection.
    void task.catch(() => undefined);
  }
}

/**
 * A PostHog event whose properties are built by a trusted caller
 * (`observability.ts`, `exceptionEvent.ts`): operational Error Tracking
 * exceptions. Identity handling matches
 * `captureCoderouterEvent`.
 */
export type CoderouterRawEvent = {
  readonly event: "$ai_trace" | "$ai_span" | "$exception" | "coderouter_alert";
  readonly userId?: string;
  readonly teamId?: string;
  /** Event timestamp; defaults to now. */
  readonly timestamp?: string;
  readonly properties: Readonly<Record<string, CoderouterRawProperty>>;
};

/** Property keys a raw event may carry; anything else is dropped. */
const RAW_EVENT_KEY = /^(\$ai_[a-z_]+|\$exception_[a-z_]+|coderouter_[a-z_]+|trace_id|vercel_request_id|team_id|upstream_kind|upstream_account_id|provider|agent|attempt|attempts|status|outcome|failure_stage|failure_code|healthy|total|sticky|cooldown_ms|forced|surface|reason|alert_key|severity|title|count|threshold|window_minutes)$/;

/**
 * Sends one batch of operational exception/alert events. Same gate, config, identity and
 * deferred delivery as `captureCoderouterEvent`; the closed schema here is
 * the key allow-list.
 */
export function captureCoderouterRawBatch(
  events: readonly CoderouterRawEvent[],
  dependencies: AnalyticsDependencies = defaultDependencies,
): void {
  // PostHog is not a CodeRouter request or token ledger. Keep the legacy
  // trace shape available to callers and tests, but refuse to transmit it.
  const operationalEvents = events.filter(
    (entry) => entry.event !== "$ai_trace" && entry.event !== "$ai_span",
  );
  if (operationalEvents.length === 0 || !dependencies.enabled()) return;
  const config = dependencies.config();
  if (!config) return;
  const now = new Date().toISOString();
  const batch = operationalEvents.map((entry) => {
    const properties: Record<string, CoderouterRawProperty> = {};
    for (const [key, value] of Object.entries(entry.properties)) {
      if (RAW_EVENT_KEY.test(key)) properties[key] = value;
    }
    return {
      event: entry.event,
      ...identity(entry.userId, entry.teamId),
      properties: {
        ...properties,
        $geoip_disable: true,
        ...personProperties(entry.userId, entry.teamId),
        $insert_id: randomUUID(),
        product: "coderouter",
        schema_version: ANALYTICS_SCHEMA_VERSION,
        service_version: ANALYTICS_SERVICE_VERSION,
      },
      timestamp: entry.timestamp ?? now,
    };
  });
  const body = JSON.stringify({ api_key: config.projectKey, batch });
  const task = deliver(body, dependencies.fetch, config.ingestHost).catch(
    (error) => {
      // Reporting this failure through the same PostHog sink would recurse
      // forever while the sink is unavailable. Sentry still receives the
      // structured delivery failure through reportCoderouterFailure.
      reportCoderouterFailure("analytics_delivery", error);
    },
  );
  dependencies.defer(task);
}

const defaultDependencies: AnalyticsDependencies = {
  fetch,
  defer: deferCoderouterTask,
  enabled: () =>
    process.env.VERCEL_ENV === "production" ||
    process.env.CODEROUTER_ANALYTICS_FORCE === "1",
  config: coderouterAnalyticsConfig,
};

/**
 * The PostHog identity of one event: the Stack user when known (a person
 * profile the cmux apps also write to), else the server identity with person
 * processing off so anonymous events never create phantom persons.
 */
function identity(userId: string | undefined, teamId: string | undefined): { distinct_id: string } {
  const user = analyticsId(userId);
  if (user) return { distinct_id: user };
  return { distinct_id: teamId ? `coderouter-team:${analyticsId(teamId) ?? "unknown"}` : SERVER_DISTINCT_ID };
}

function personProperties(
  userId: string | undefined,
  teamId: string | undefined,
): Record<string, AnalyticsScalar> {
  const user = analyticsId(userId);
  const team = analyticsId(teamId);
  return {
    ...(user ? { user_id: user } : { $process_person_profile: false }),
    ...(team ? { team_id: team } : {}),
  };
}

/** Opaque identifiers only: a Stack user id or team id is `[A-Za-z0-9_-]`. */
function analyticsId(value: string | undefined): string | null {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value) ? value : null;
}

/**
 * Best-effort, server-only CodeRouter analytics. The payload is rebuilt from a
 * closed event/property schema; caller-provided keys and free-form strings are
 * never forwarded.
 */
export function captureCoderouterEvent(
  input: CaptureInput,
  dependencies: AnalyticsDependencies = defaultDependencies,
): void {
  if (!dependencies.enabled()) return;
  const config = dependencies.config();
  if (!config) return;

  const properties = eventProperties(input.event, input.properties ?? {});
  if (!properties) return;

  // Account lifecycle events describe one person's action and are dropped
  // rather than attributed to nobody.
  if (eventNeedsUser(input.event) && !input.userId) return;
  const body = JSON.stringify({
    api_key: config.projectKey,
    batch: [
      {
        event: input.event,
        ...identity(input.userId, input.teamId),
        properties: {
          ...properties,
          $geoip_disable: true,
          ...personProperties(input.userId, input.teamId),
          $insert_id: randomUUID(),
          product: "coderouter",
          schema_version: ANALYTICS_SCHEMA_VERSION,
          service_version: ANALYTICS_SERVICE_VERSION,
        },
        timestamp: new Date().toISOString(),
      },
    ],
  });
  const task = deliver(body, dependencies.fetch, config.ingestHost).catch(
    (error) => {
      reportCoderouterFailure("analytics_delivery", error);
    },
  );
  dependencies.defer(task);
}

async function deliver(
  body: string,
  posthogFetch: typeof fetch,
  posthogHost: string,
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

function eventNeedsUser(event: CoderouterAnalyticsEvent): boolean {
  return event === "coderouter_account_added" ||
    event === "coderouter_account_removed" ||
    event === "coderouter_route_session_issued" ||
    event === "coderouter_route_session_revoked" ||
    event === "coderouter_claude_upstream_set" ||
    event === "coderouter_claude_upstream_removed";
}

function eventProperties(
  event: CoderouterAnalyticsEvent,
  input: Readonly<Record<string, AnalyticsScalar | null | undefined>>,
): Record<string, AnalyticsScalar> | null {
  switch (event) {
    case "coderouter_model_request_completed":
      // Deprecated compatibility input. Usage is recorded only by
      // `usageLedger.ts` in ClickHouse.
      return null;
    case "coderouter_account_added": {
      const provider = accountProvider(input.provider);
      const source = lifecycleSource(input.source);
      if (!provider || !source || typeof input.already_exists !== "boolean") {
        return null;
      }
      return { provider, source, already_exists: input.already_exists };
    }
    case "coderouter_account_removed": {
      const source = lifecycleSource(input.source);
      if (!source) return null;
      const output: Record<string, AnalyticsScalar> = { source };
      if (typeof input.last_account === "boolean") {
        output.last_account = input.last_account;
      }
      if (typeof input.legacy_cleanup_pending === "boolean") {
        output.legacy_cleanup_pending = input.legacy_cleanup_pending;
      }
      return output;
    }
    case "coderouter_account_status_viewed":
      return {
        source: lifecycleSource(input.source) ?? "native_api",
        account_count_bucket: countBucket(input.account_count),
        account_error_count_bucket: countBucket(input.account_error_count),
        latency_bucket: latencyBucket(input.duration_ms),
      };
    case "coderouter_auth_rejected": {
      const surface = authSurface(input.surface);
      const reason = authReason(input.reason);
      return surface && reason ? { surface, reason } : null;
    }
    case "coderouter_route_session_issued":
    case "coderouter_route_session_revoked":
      return {};
    case "coderouter_organization_catalog_viewed":
      return {
        organization_count_bucket: countBucket(input.organization_count),
        has_selected_organization:
          input.has_selected_organization === true,
      };
    case "coderouter_metrics_loaded": {
      const outcome = enumValue(input.outcome, ["ready", "unavailable"]);
      const failureStage = enumValue(input.failure_stage, [
        "none",
        "configuration",
        "request",
        "endpoint_status",
        "response_parse",
        "response_validation",
      ]);
      return outcome && failureStage
        ? { outcome, failure_stage: failureStage }
        : null;
    }
    case "coderouter_vm_usage_viewed": {
      const surface = enumValue(input.surface, [
        "dashboard",
        "vm_usage_api",
        "team_machines_api",
        "vm_self_api",
      ]);
      const outcome = enumValue(input.outcome, ["ready", "unavailable"]);
      return surface && outcome ? { surface, outcome } : null;
    }
    case "coderouter_cli_command_started":
    case "coderouter_cli_command_completed":
      return cliCommandProperties(input);
    case "coderouter_claude_upstream_set": {
      const upstreamKind = claudeUpstreamKind(input.upstream_kind);
      if (!upstreamKind || typeof input.replaced !== "boolean") return null;
      return { upstream_kind: upstreamKind, replaced: input.replaced };
    }
    case "coderouter_claude_upstream_removed":
      return {};
  }
}

function cliCommandProperties(
  input: Readonly<Record<string, AnalyticsScalar | null | undefined>>,
): Record<string, AnalyticsScalar> | null {
  const command = enumValue(input.command, [
    "accounts", "help", "version", "agent", "add", "remove", "login",
    "logout", "organization", "upgrade", "doctor", "unknown",
  ]);
  const agent = enumValue(input.agent, ["none", "codex", "opencode", "pi"]);
  const mode = enumValue(input.mode, [
    "summary", "default", "routed", "direct", "interactive", "specified",
    "cancel", "unknown", "code", "device", "current", "list", "switch",
  ]);
  const outcome = enumValue(input.outcome, [
    "started", "success", "failure", "cancelled",
  ]);
  const failureStage = enumValue(input.failure_stage, [
    "none", "validation", "control_plane", "child_start", "local_io",
    "child_process",
  ]);
  const exitCodeClass = enumValue(input.exit_code_class, [
    "not_applicable", "success", "generic_failure", "usage",
    "launch_failure", "signal_or_terminated", "other_failure",
  ]);
  const durationBucket = enumValue(input.duration_bucket, [
    "not_applicable", "under_1s", "1s_to_5s", "5s_to_30s",
    "30s_to_2m", "2m_or_more",
  ]);
  const executionContext = enumValue(input.execution_context, [
    "interactive", "headless",
  ]);
  const cliVersion = typeof input.cli_version === "string" &&
      input.cli_version.length <= 64 &&
      /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(input.cli_version)
    ? input.cli_version
    : null;
  return command && agent && mode && outcome && failureStage &&
      exitCodeClass && durationBucket && executionContext && cliVersion
    ? {
      command,
      agent,
      mode,
      outcome,
      failure_stage: failureStage,
      exit_code_class: exitCodeClass,
      duration_bucket: durationBucket,
      execution_context: executionContext,
      cli_version: cliVersion,
    }
    : null;
}

function accountProvider(value: unknown): string | null {
  return enumValue(value, [
    "codex",
    "claude",
    "openai-apikey",
    "anthropic-apikey",
    "opencode-go",
  ]);
}

function lifecycleSource(value: unknown): string | null {
  return enumValue(value ?? "native_api", ["native_api", "legacy_dashboard"]);
}


function claudeUpstreamKind(value: unknown): string | null {
  return enumValue(value, ["anthropic_api_key", "anthropic_oauth", "bedrock"]);
}

function authSurface(value: unknown): string | null {
  return enumValue(value, [
    "responses",
    "models",
    "messages",
    "count_tokens",
    "opencode_config",
    "opencode_proxy",
    "session_validation",
    "vm_usage",
  ]);
}

function authReason(value: unknown): string | null {
  return enumValue(value, [
    "missing_route_token",
    "invalid_route_token",
    "vm_mismatch",
  ]);
}

function enumValue<const Value extends string>(
  value: unknown,
  allowed: readonly Value[],
): Value | null {
  return typeof value === "string" && allowed.includes(value as Value)
    ? value as Value
    : null;
}

function countBucket(value: unknown): string {
  const count = boundedNumber(value, MAX_COUNT);
  if (count === null || count === 0) return "0";
  if (count === 1) return "1";
  if (count <= 3) return "2-3";
  if (count <= 10) return "4-10";
  if (count <= 50) return "11-50";
  return "51+";
}

function latencyBucket(value: unknown): string {
  const milliseconds = boundedNumber(value, 24 * 60 * 60 * 1_000);
  if (milliseconds === null) return "unknown";
  if (milliseconds < 100) return "lt_100ms";
  if (milliseconds < 500) return "100_499ms";
  if (milliseconds < 2_000) return "500_1999ms";
  if (milliseconds < 10_000) return "2_9s";
  if (milliseconds < 60_000) return "10_59s";
  return "60s_plus";
}



function boundedNumber(value: unknown, maximum: number): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 &&
      value <= maximum
    ? value
    : null;
}

/** The main cmux project, same key and capture host as every other server sink. */
export function coderouterAnalyticsConfig(): CoderouterAnalyticsConfig | null {
  const projectKey = POSTHOG_PROJECT_KEY?.trim();
  if (!projectKey) return null;
  return { projectKey, ingestHost: POSTHOG_HOST };
}

export const __test = {
  eventProperties,
  deliver,
};
