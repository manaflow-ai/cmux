import type { Environment } from "./environment";

/**
 * Telemetry is deliberately best effort. The request or socket operation must
 * never wait for a third party sink, and sink payloads contain no credentials,
 * request bodies, terminal data, SQL, or private addresses.
 */
export type ObservabilityContext = { waitUntil(promise: Promise<unknown>): void };
export type ObservabilityEvent = {
  event: string;
  [key: string]: unknown;
};

const MAX_EVENT_BYTES = 8 * 1024;
const SINK_TIMEOUT_MS = 500;
const MAX_IN_FLIGHT = 16;
const SECRET_KEY = /(authorization|cookie|token|secret|password|signature|nonce|body|payload|sql|private.?key|dsn|credential|relayurl|address)/i;
let inFlight = 0;
let dropped = 0;

function safeValue(value: unknown, depth = 0): unknown {
  if (depth > 3) return "[truncated]";
  if (typeof value === "string") return value.length > 256 ? `${value.slice(0, 256)}...[truncated]` : value;
  if (typeof value === "number" || typeof value === "boolean" || value === null) return value;
  if (Array.isArray(value)) return value.slice(0, 32).map(item => safeValue(item, depth + 1));
  if (typeof value === "object") {
    const output: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>).slice(0, 64)) {
      if (SECRET_KEY.test(key)) continue;
      output[key] = safeValue(item, depth + 1);
    }
    return output;
  }
  return String(value);
}

function prepare(event: ObservabilityEvent): Record<string, unknown> {
  const value = safeValue({ ...event, observedAt: new Date().toISOString() }) as Record<string, unknown>;
  const encoded = JSON.stringify(value);
  if (new TextEncoder().encode(encoded).byteLength <= MAX_EVENT_BYTES) return value;
  return { event: String(event.event).slice(0, 96), observedAt: value.observedAt, truncated: true };
}

async function withTimeout(request: RequestInfo | URL, init: RequestInit): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SINK_TIMEOUT_MS);
  try {
    const response = await fetch(request, { ...init, signal: controller.signal });
    // Consume a bounded response body before ending the timeout budget. This
    // prevents a sink that stalls after headers from retaining the invocation.
    const reader = response.body?.getReader();
    if (reader) {
      let bytes = 0;
      while (bytes <= 64 * 1024) {
        const next = await reader.read();
        if (next.done) break;
        bytes += next.value.byteLength;
        if (bytes > 64 * 1024) await reader.cancel("observability response too large");
      }
    }
    return response;
  } finally { clearTimeout(timer); }
}

async function sendAxiom(env: Environment, event: Record<string, unknown>): Promise<void> {
  const token = env.AXIOM_TOKEN;
  const dataset = env.AXIOM_DATASET;
  if (!token || !dataset) return;
  const endpoint = env.AXIOM_INGEST_URL || `https://api.axiom.co/v1/datasets/${encodeURIComponent(dataset)}/ingest`;
  const response = await withTimeout(endpoint, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify([event]),
  });
  if (!response.ok) throw new Error(`axiom_${response.status}`);
}

async function sendSentry(env: Environment, event: Record<string, unknown>): Promise<void> {
  if (!env.SENTRY_DSN) return;
  const match = /^https:\/\/([^@]+)@([^/]+)\/(\d+)$/.exec(env.SENTRY_DSN);
  if (!match) throw new Error("sentry_dsn_invalid");
  const key = match[1] ?? ""; const host = match[2] ?? ""; const project = match[3] ?? "";
  const eventId = crypto.randomUUID().replaceAll("-", "");
  const response = await withTimeout(`https://${host}/api/${project}/store/?sentry_version=7&sentry_key=${encodeURIComponent(key)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      event_id: eventId, timestamp: event.observedAt, platform: "javascript", environment: env.SENTRY_ENVIRONMENT || env.ENVIRONMENT,
      level: "error", logger: "iroh-v2", message: String(event.code || event.event), tags: { event: String(event.event) },
    }),
  });
  if (!response.ok) throw new Error(`sentry_${response.status}`);
}

export function observe(ctx: ObservabilityContext, env: Environment, input: ObservabilityEvent): void {
  const event = prepare(input);
  console.log(JSON.stringify(event));
  if (inFlight >= MAX_IN_FLIGHT) {
    dropped = Math.min(dropped + 1, 1_000_000_000);
    console.warn(JSON.stringify({ event: "iroh.observability.events_dropped", count: dropped, limit: MAX_IN_FLIGHT }));
    return;
  }
  inFlight += 1;
  const status = typeof event.status === "number" ? event.status : 0;
  const isException = status >= 500 || /exception|internal_error|upstream_unavailable/i.test(String(event.code || event.event));
  const send = Promise.allSettled([sendAxiom(env, event), isException ? sendSentry(env, event) : Promise.resolve()])
    .then(results => { for (const result of results) if (result.status === "rejected") console.warn(JSON.stringify({ event: "iroh.observability.sink_failed", sink: result.reason instanceof Error ? result.reason.message.slice(0, 64) : "unknown" })); })
    .finally(() => { inFlight -= 1; });
  ctx.waitUntil(send);
}
