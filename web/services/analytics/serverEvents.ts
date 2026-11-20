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
import { createHash, randomUUID } from "node:crypto";
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
  /**
   * Send without a person profile (`$process_person_profile: false`) for a
   * key that is not a real person (a deleted account placeholder).
   */
  readonly personless?: boolean;
};

export type ServerEventTask = () => Promise<void>;

export type ServerEventDependencies = {
  readonly fetch: typeof fetch;
  readonly env: Record<string, string | undefined>;
  readonly defer: (task: ServerEventTask) => void;
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
 * Run a lazy best-effort task past the response. Outside a Next request scope
 * (tests, scripts) `after` throws, so run the task immediately.
 */
export function deferServerTask(task: ServerEventTask): void {
  try {
    after(() => task());
  } catch {
    try {
      void task();
    } catch {
      // A best-effort task must not escape a request-scope lifecycle race.
    }
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
  const distinctId = normalizedOpaqueId(input.distinctId);
  if (!distinctId) return null;
  const teamId = normalizedOpaqueId(input.teamId);
  const insertId = normalizedInsertId(input.insertId);
  const properties: Record<string, unknown> = {
    ...cleanProperties(input.properties),
    $lib: SERVER_EVENT_LIB,
    $insert_id: insertId ?? randomUUID(),
    // Server IPs are Vercel's, not the user's; never geolocate them.
    $geoip_disable: true,
  };
  if (teamId) properties.$groups = { [STACK_TEAM_GROUP]: teamId };
  if (input.personless) {
    properties.$process_person_profile = false;
  } else {
    const set = cleanProperties(input.set);
    if (Object.keys(set).length > 0) properties.$set = set;
    const setOnce = cleanProperties(input.setOnce);
    if (Object.keys(setOnce).length > 0) properties.$set_once = setOnce;
  }
  return {
    api_key: POSTHOG_PROJECT_KEY,
    event: input.event,
    distinct_id: distinctId,
    timestamp: (input.timestamp ?? now).toISOString(),
    properties,
    // PostHog deduplicates on the event uuid, not `$insert_id`. A natural key
    // maps to a stable uuid so a retry or replay of the same fact collapses.
    ...(insertId ? { uuid: uuidFromKey(insertId) } : {}),
  };
}

/**
 * Capture one product event. Delivery starts only when the deferred callback
 * runs. The returned promise settles when delivery is done and never rejects,
 * so callers may ignore it.
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
  const posthogHost = configuredPosthogHost(deps.env);
  let resolveDelivery!: () => void;
  const delivery = new Promise<void>((resolve) => {
    resolveDelivery = resolve;
  });
  let started = false;
  const task: ServerEventTask = async () => {
    if (started) return;
    started = true;
    try {
      if (!isAllowedPosthogHost(posthogHost, deps.env)) {
        throw new Error("PostHog host must use HTTPS");
      }
      await deliver(JSON.stringify(payload), deps.fetch, posthogHost);
    } catch (error: unknown) {
      console.warn("[analytics] server event delivery failed", {
        event: input.event,
        error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
      });
    } finally {
      resolveDelivery();
    }
  };
  try {
    deps.defer(task);
  } catch {
    // A custom defer implementation or a framework lifecycle race must not
    // turn best-effort analytics into a request failure. Run the task now so
    // callers waiting on the returned promise cannot be left pending.
    try {
      void task();
    } catch {
      resolveDelivery();
    }
  }
  return delivery;
}

/** Events per `/batch/` request; PostHog accepts far larger bodies, this keeps each request small. */
export const SERVER_EVENT_BATCH_SIZE = 200;

export type ServerEventBatchResult = {
  readonly sent: number;
  readonly failed: number;
};

/**
 * Deliver many product events now, in `/batch/` requests of
 * SERVER_EVENT_BATCH_SIZE, and report how many were accepted. For cron jobs
 * that own their run and must await delivery before answering; request paths
 * use `captureServerEvent`. Same gating as `captureServerEvent`; never throws.
 */
export async function captureServerEventBatch(
  inputs: readonly ServerEventInput[],
  dependencies: Partial<ServerEventDependencies> = {},
): Promise<ServerEventBatchResult> {
  const deps: ServerEventDependencies = { ...defaultDependencies, ...dependencies };
  if (isAnalyticsTestRun(deps.env) && !dependencies.fetch) return { sent: 0, failed: 0 };
  if (!serverAnalyticsEnabled(deps.env)) return { sent: 0, failed: 0 };
  const posthogHost = configuredPosthogHost(deps.env);
  if (!isAllowedPosthogHost(posthogHost, deps.env)) return { sent: 0, failed: inputs.length };
  const now = deps.now();
  const batch = inputs.flatMap((input) => {
    const payload = serverEventPayload(input, now);
    if (!payload) return [];
    // The key travels once at the top of the batch body.
    const event: Record<string, unknown> = { ...payload };
    delete event.api_key;
    return [event];
  });
  let sent = 0;
  let failed = inputs.length - batch.length;
  for (let start = 0; start < batch.length; start += SERVER_EVENT_BATCH_SIZE) {
    const chunk = batch.slice(start, start + SERVER_EVENT_BATCH_SIZE);
    try {
      await deliver(JSON.stringify({ api_key: POSTHOG_PROJECT_KEY, batch: chunk }), deps.fetch, posthogHost, "/batch/");
      sent += chunk.length;
    } catch (error: unknown) {
      failed += chunk.length;
      console.warn("[analytics] server event batch delivery failed", {
        events: chunk.length,
        error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
      });
    }
  }
  return { sent, failed };
}

export function isSecurePosthogHost(host: string): boolean {
  try {
    const url = new URL(host);
    return url.protocol === "https:" && url.hostname.length > 0 && !url.username && !url.password;
  } catch {
    return false;
  }
}

/** Localhost is allowed only for the explicit smoke harness. Production and
 * preview always require HTTPS, so a misconfigured host cannot exfiltrate
 * person or team analytics over clear text.
 */
export function isAllowedPosthogHost(
  host: string,
  env: Record<string, string | undefined> = process.env,
): boolean {
  if (isSecurePosthogHost(host)) return true;
  if (env.CMUX_SERVER_ANALYTICS_SMOKE !== "1") return false;
  try {
    const url = new URL(host);
    return url.protocol === "http:" &&
      (url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "::1" || url.hostname === "[::1]") &&
      !url.username && !url.password;
  } catch {
    return false;
  }
}

function configuredPosthogHost(env: Record<string, string | undefined>): string {
  return (env.POSTHOG_HOST ?? POSTHOG_HOST).replace(/\/$/, "");
}

async function deliver(
  body: string,
  fetchImpl: typeof fetch,
  posthogHost: string,
  path: "/capture/" | "/batch/" = "/capture/",
): Promise<void> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Response;
    try {
      response = await fetchImpl(`${posthogHost}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        redirect: "error",
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

function normalizedOpaqueId(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed && /^[A-Za-z0-9_-]{1,128}$/.test(trimmed) ? trimmed : null;
}

/** A stable RFC 4122 version-5-shaped uuid from a natural key. */
function uuidFromKey(key: string): string {
  const bytes = createHash("sha1").update(`cmux-server-event:${key}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function normalizedInsertId(value: string | undefined): string | null {
  const trimmed = value?.trim();
  if (!trimmed) return null;
  // Natural keys are generated by trusted server code. Keep the grammar
  // bounded anyway so a caller cannot smuggle a header, URL or unbounded text
  // into PostHog's dedupe field.
  return /^[A-Za-z0-9._:-]{1,200}$/.test(trimmed) ? trimmed : null;
}
