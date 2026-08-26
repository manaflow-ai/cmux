// Server-side product analytics for the Cloud VM control plane.
//
// ONE module owns every PostHog capture for the VM lifecycle so callers stay
// one-line hooks: the usage-event chokepoint (`VmRepository.recordUsageEvent`)
// forwards persisted lifecycle events (vm.created, vm.create.failed,
// vm.resumed, vm.destroyed, vm.attach, vm.create.credit.*, ...), and route
// handlers add the few signals the chokepoint cannot know — request duration
// and outcome (`vm.create.completed`, `vm.attach.completed`), the paywall
// funnel (`vm.limit_hit`), and desktop opens (`vm.desktop.opened`).
//
// Analytics must never fail or slow a request: every capture is
// fire-and-forget behind a hard timeout and swallows all transport failures.
// Properties are allowlisted to scalars and scrubbed of anything that smells
// like a token, credential, lease, or command string.

import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";

export type VmAnalyticsScalar = string | number | boolean | null;
export type VmAnalyticsProperties = Record<string, VmAnalyticsScalar>;

const CAPTURE_TIMEOUT_MS = 2_000;
const MAX_STRING_PROPERTY_LENGTH = 200;

/** Keys whose values must never leave the control plane, whatever they hold. */
const SENSITIVE_KEY_PATTERN =
  /(token|secret|password|credential|cookie|lease|authorization|api[_-]?key|bearer|private)/i;
/** Raw command strings are user data; `commandLength` and friends stay. */
const COMMAND_STRING_KEY_PATTERN = /^(command|cmd|args|argv|script)$/i;

export type VmAnalyticsOptions = {
  /** Test seam. Defaults to global fetch. */
  readonly fetchImpl?: typeof fetch;
  /** Test seam. Defaults to process.env. */
  readonly env?: Record<string, string | undefined>;
};

export function vmAnalyticsEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  if (env.CMUX_VM_ANALYTICS_DISABLED === "1") return false;
  return env.VERCEL_ENV === "production" || env.CMUX_VM_ANALYTICS_FORCE === "1";
}

/**
 * Fire-and-forget capture. Returns a promise that never rejects so tests can
 * await settlement; production callers ignore the return value.
 */
export function captureVmAnalyticsEvent(
  input: {
    readonly event: string;
    readonly distinctId: string;
    readonly properties?: VmAnalyticsProperties;
  },
  options: VmAnalyticsOptions = {},
): Promise<void> {
  const env = options.env ?? process.env;
  if (!vmAnalyticsEnabled(env)) return Promise.resolve();
  const doFetch = options.fetchImpl ?? fetch;
  let body: string;
  try {
    body = JSON.stringify({
      api_key: POSTHOG_PROJECT_KEY,
      event: input.event,
      distinct_id: input.distinctId,
      properties: {
        ...input.properties,
        schema_version: 1,
        $insert_id: randomUUID(),
        // The server's egress IP says nothing about the user.
        $geoip_disable: true,
      },
      timestamp: new Date().toISOString(),
    });
  } catch {
    return Promise.resolve();
  }
  const task = Promise.resolve()
    .then(() =>
      doFetch(`${POSTHOG_HOST}/capture/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(CAPTURE_TIMEOUT_MS),
      }),
    )
    .then(() => undefined)
    .catch(() => undefined);
  // Keep the serverless function alive until the capture settles when the
  // request context supports it; outside a request just detach.
  try {
    after(task);
  } catch {
    void task;
  }
  return task;
}

/** Only scalar, non-sensitive, bounded metadata becomes event properties. */
export function sanitizedVmEventProperties(
  metadata: Record<string, unknown> | undefined,
): VmAnalyticsProperties {
  const properties: VmAnalyticsProperties = {};
  if (!metadata) return properties;
  for (const [key, value] of Object.entries(metadata)) {
    if (SENSITIVE_KEY_PATTERN.test(key) || COMMAND_STRING_KEY_PATTERN.test(key)) continue;
    if (value === null) {
      properties[key] = null;
      continue;
    }
    if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) {
      properties[key] = value;
      continue;
    }
    if (typeof value === "string") {
      properties[key] = value.slice(0, MAX_STRING_PROPERTY_LENGTH);
    }
    // Objects, arrays, functions, symbols, bigints: dropped by design.
  }
  return properties;
}

/** Shape of `VmRepository.recordUsageEvent` input; kept structural so the
 * repository hook stays a one-liner with no import cycle. */
export type VmUsageEventAnalyticsInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly billingPlanId?: string | null;
  readonly vmId?: string | null;
  readonly eventType: string;
  readonly provider?: string;
  readonly imageId?: string;
  readonly metadata?: Record<string, unknown>;
};

/**
 * Chokepoint hook: every persisted Cloud VM usage event is mirrored to
 * PostHog under its `eventType` name. Never throws.
 */
export function captureVmUsageEvents(
  inputs: readonly VmUsageEventAnalyticsInput[],
  options: VmAnalyticsOptions = {},
): void {
  for (const input of inputs) {
    try {
      const properties: VmAnalyticsProperties = {
        ...sanitizedVmEventProperties(input.metadata),
        ...(input.provider ? { provider: input.provider } : {}),
        ...(input.imageId ? { image: input.imageId.slice(0, MAX_STRING_PROPERTY_LENGTH) } : {}),
        ...(input.billingPlanId ? { plan_id: input.billingPlanId } : {}),
        team_scoped: !!input.billingTeamId,
        vm_row_id_set: !!input.vmId,
      };
      if (input.eventType === "vm.attach") {
        properties.reattach = input.metadata?.requestedSessionId != null;
      }
      void captureVmAnalyticsEvent(
        { event: input.eventType, distinctId: input.userId, properties },
        options,
      );
    } catch {
      // Analytics never breaks usage-event persistence.
    }
  }
}

/** Route-layer: create latency and outcome, with per-stage timings. */
export function captureVmCreateCompleted(
  input: {
    readonly userId: string;
    readonly provider?: string | null;
    readonly image?: string | null;
    readonly planId?: string | null;
    readonly memoryMb?: number | null;
    readonly status: number;
    readonly durationMs: number;
    readonly timings?: Record<string, number>;
  },
  options: VmAnalyticsOptions = {},
): void {
  const properties: VmAnalyticsProperties = {
    outcome: input.status < 400 ? "success" : "failure",
    http_status: input.status,
    duration_ms: Math.round(input.durationMs),
    ...(input.provider ? { provider: input.provider } : {}),
    ...(input.image ? { image: input.image.slice(0, MAX_STRING_PROPERTY_LENGTH) } : {}),
    ...(input.planId ? { plan_id: input.planId } : {}),
    ...(typeof input.memoryMb === "number" ? { memory_mb: input.memoryMb } : {}),
  };
  for (const [stage, ms] of Object.entries(input.timings ?? {})) {
    if (Number.isFinite(ms)) properties[`timing_${stage}_ms`] = ms;
  }
  void captureVmAnalyticsEvent(
    { event: "vm.create.completed", distinctId: input.userId, properties },
    options,
  );
}

/** Route-layer: attach latency and reconnect-vs-fresh. */
export function captureVmAttachCompleted(
  input: {
    readonly userId: string;
    readonly reattach: boolean;
    readonly requireDaemon: boolean;
    readonly transport?: string | null;
    readonly status: number;
    readonly durationMs: number;
  },
  options: VmAnalyticsOptions = {},
): void {
  void captureVmAnalyticsEvent(
    {
      event: "vm.attach.completed",
      distinctId: input.userId,
      properties: {
        outcome: input.status < 400 ? "success" : "failure",
        http_status: input.status,
        duration_ms: Math.round(input.durationMs),
        reattach: input.reattach,
        require_daemon: input.requireDaemon,
        ...(input.transport ? { transport: input.transport } : {}),
      },
    },
    options,
  );
}

/**
 * Paywall funnel: a provisioning verb hit the active-VM limit. On free plans
 * the response doubles as the upgrade prompt (`upgrade_shown`).
 */
export function captureVmLimitHit(
  input: {
    readonly userId: string;
    readonly planId: string;
    readonly limit: number;
    readonly upgradeShown: boolean;
    readonly phase?: string;
  },
  options: VmAnalyticsOptions = {},
): void {
  void captureVmAnalyticsEvent(
    {
      event: "vm.limit_hit",
      distinctId: input.userId,
      properties: {
        plan_id: input.planId,
        limit: input.limit,
        upgrade_shown: input.upgradeShown,
        ...(input.phase ? { phase: input.phase } : {}),
      },
    },
    options,
  );
}

/**
 * Workflow-layer: a suspended VM was woken by a user-facing verb. Captured for
 * every control-plane resume (the persisted `vm.resumed` usage event is only
 * recorded for reserved team resumes), so wake latency is measurable per
 * provider and per triggering verb.
 */
export function captureVmWakeCompleted(
  input: {
    readonly userId: string;
    readonly provider: string;
    readonly source: string;
    readonly durationMs: number;
    readonly reserved: boolean;
  },
  options: VmAnalyticsOptions = {},
): void {
  void captureVmAnalyticsEvent(
    {
      event: "vm.wake.completed",
      distinctId: input.userId,
      properties: {
        provider: input.provider,
        source: input.source,
        duration_ms: Math.round(input.durationMs),
        reserved: input.reserved,
      },
    },
    options,
  );
}

/** Route-layer: a port open that produced a cmux desktop (noVNC) wrapper URL. */
export function captureVmDesktopOpened(
  input: {
    readonly userId: string;
    readonly port: number;
    readonly wrapped: boolean;
  },
  options: VmAnalyticsOptions = {},
): void {
  void captureVmAnalyticsEvent(
    {
      event: "vm.desktop.opened",
      distinctId: input.userId,
      properties: { port: input.port, wrapped: input.wrapped },
    },
    options,
  );
}
