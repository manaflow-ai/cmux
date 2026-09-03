// Server-side product analytics for the main PostHog project.
//
// One sender for every product event the web server emits, so identity is
// uniform across Cloud VMs, CodeRouter and billing: `distinct_id` is the
// Stack user id (the same id the signed-in web, iOS and Stripe webhook events
// use), the billing team is the `stack_team` group, and the plan lands on the
// person profile through `$set`. Operational signals (request failures,
// `$exception`, alerts, reaper runs) keep their own senders in
// `services/vms/observability.ts`; this module is for events a product
// analyst counts, funnels and retains on.
//
// Delivery is best effort: bounded timeout, one retry on transient failure,
// deferred past the response with `after()`, never throws into the caller.
import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { isAnalyticsTestRun, POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "./iosEventPolicy";

export type ServerEventScalar = string | number | boolean;
export type ServerEventProperties = Readonly<Record<string, ServerEventScalar | null | undefined>>;

export type ServerEventInput = {
  readonly event: string;
  /**
   * Stack user id. An event without a person is not product analytics; use an
   * operational sender for those.
   */
  readonly distinctId: string;
  /** Stack team id. Becomes the `stack_team` group so account-level rollups work. */
  readonly teamId?: string | null;
  readonly properties?: ServerEventProperties;
  /** Person properties to overwrite (`billing_plan`, `billing_customer_type`). */
  readonly set?: ServerEventProperties;
  /** Person properties written once (`cloud_vm_first_created_at`, ...). */
  readonly setOnce?: ServerEventProperties;
  /**
   * Dedupe key. Give a natural key (`cloud_vm_created:<vm id>`) when the same
   * fact can be emitted twice (retries, replays); defaults to a random UUID.
   */
  readonly insertId?: string;
  readonly timestamp?: Date;
};

export type ServerEventDependencies = {
  readonly fetch: typeof fetch;
  readonly env: Record<string, string | undefined>;
  readonly defer: (task: Promise<unknown>) => void;
  readonly now: () => Date;
};

/** Env flag that turns the sender on outside production (staging smoke tests). */
export const SERVER_ANALYTICS_FORCE_ENV = "CMUX_SERVER_ANALYTICS_FORCE";
export const SERVER_EVENT_LIB = "cmux-web-server";
export const STACK_TEAM_GROUP = "stack_team";

const CAPTURE_TIMEOUT_MS = 2_000;
const MAX_STRING_LENGTH = 500;
const MAX_PROPERTIES = 64;
const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);

export function serverAnalyticsEnabled(env: Record<string, string | undefined>): boolean {
  return env.VERCEL_ENV === "production" || env[SERVER_ANALYTICS_FORCE_ENV] === "1";
}

/**
 * Run a best-effort task past the response. Outside a Next request scope
 * (tests, scripts) `after` throws; the promise is already running, so only
 * its rejection needs absorbing.
 */
export function deferServerTask(task: Promise<unknown>): void {
  try {
    after(() => task);
  } catch {
    void task.catch(() => undefined);
  }
}

const defaultDependencies: ServerEventDependencies = {
  fetch: (input, init) => fetch(input, init),
  env: process.env,
  defer: deferServerTask,
  now: () => new Date(),
};

/**
 * Build the PostHog `/capture/` payload for one event. Pure, so the mapping
 * from our inputs to the wire shape is unit-testable without a transport.
 * Returns null when the event has no usable person.
 */
export function serverEventPayload(
  input: ServerEventInput,
  now: Date = new Date(),
): Record<string, unknown> | null {
  const distinctId = input.distinctId.trim();
  if (!distinctId) return null;
  const teamId = normalizedId(input.teamId);
  const properties: Record<string, unknown> = {
    ...cleanProperties(input.properties),
    $lib: SERVER_EVENT_LIB,
    $insert_id: input.insertId?.slice(0, 200) ?? randomUUID(),
    // Server IPs are Vercel's, not the user's; never geolocate them.
    $geoip_disable: true,
  };
  if (teamId) properties.$groups = { [STACK_TEAM_GROUP]: teamId };
  const set = cleanProperties(input.set);
  if (Object.keys(set).length > 0) properties.$set = set;
  const setOnce = cleanProperties(input.setOnce);
  if (Object.keys(setOnce).length > 0) properties.$set_once = setOnce;
  return {
    api_key: POSTHOG_PROJECT_KEY,
    event: input.event,
    distinct_id: distinctId,
    timestamp: (input.timestamp ?? now).toISOString(),
    properties,
  };
}

/**
 * Capture one product event. Fire and forget: the returned promise settles
 * when delivery is done and never rejects, so callers may ignore it.
 */
export function captureServerEvent(
  input: ServerEventInput,
  dependencies: Partial<ServerEventDependencies> = {},
): Promise<void> {
  const deps: ServerEventDependencies = { ...defaultDependencies, ...dependencies };
  // Test runs never reach the production transport unless the test injected
  // its own fetch to inspect the payload.
  if (isAnalyticsTestRun(deps.env) && !dependencies.fetch) return Promise.resolve();
  if (!serverAnalyticsEnabled(deps.env)) return Promise.resolve();
  const payload = serverEventPayload(input, deps.now());
  if (!payload) return Promise.resolve();
  const task = deliver(JSON.stringify(payload), deps.fetch).catch((error: unknown) => {
    console.warn("[analytics] server event delivery failed", {
      event: input.event,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
  });
  deps.defer(task);
  return task;
}

async function deliver(body: string, fetchImpl: typeof fetch): Promise<void> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Response;
    try {
      response = await fetchImpl(`${POSTHOG_HOST}/capture/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(CAPTURE_TIMEOUT_MS),
      });
    } catch (error) {
      // Transport failure (timeout, DNS, reset): worth one more try.
      lastError = error;
      continue;
    }
    if (response.ok) return;
    lastError = new Error(`PostHog capture failed with status ${response.status}`);
    // A 4xx is a payload problem; retrying would only repeat it.
    if (!RETRYABLE_STATUS.has(response.status)) break;
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

function cleanProperties(properties: ServerEventProperties | undefined): Record<string, ServerEventScalar> {
  const cleaned: Record<string, ServerEventScalar> = {};
  if (!properties) return cleaned;
  let count = 0;
  for (const [key, value] of Object.entries(properties)) {
    if (value === null || value === undefined) continue;
    if (typeof value === "number" && !Number.isFinite(value)) continue;
    if (count >= MAX_PROPERTIES) break;
    cleaned[key] = typeof value === "string" ? value.slice(0, MAX_STRING_LENGTH) : value;
    count += 1;
  }
  return cleaned;
}

function normalizedId(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed.slice(0, 200) : null;
}
