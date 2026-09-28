import { SpanStatusCode } from "@opentelemetry/api";

import { withSpan } from "../telemetry";

export const MAX_TRANSPORT_JOURNAL_REQUEST_BYTES = 64 * 1_024;
export const MAX_TRANSPORT_JOURNAL_BATCH_EVENTS = 100;

// The client-side irx journal components whose events may be exported. A
// bounded set keeps sink cardinality owned by this file rather than by
// whatever a future client build emits. Chatty data-plane components
// (keepalive, terminal-trace, host-surface-lanes) are deliberately absent.
const components = new Set([
  "v2-control", "v2-host", "v2-lifecycle", "endpoint", "admission",
  "host-runtime", "engine", "broker", "control-plane", "legacy-dialect",
  "connection", "client-runtime", "registry", "host-events", "host-lanes",
  "device-list",
]);
const platforms = new Set(["mac", "ios"]);
const channels = new Set(["dev", "nightly", "production", "unknown"]);

const EVENT_PATTERN = /^[a-z0-9][a-z0-9_-]{0,47}$/;
const ATTRIBUTE_KEY_PATTERN = /^[a-z0-9][a-z0-9_]{0,31}$/;
const ENDPOINT_PATTERN = /^[0-9a-f]{12}$/;
const MAX_ATTRIBUTES = 16;
const MAX_ATTRIBUTE_VALUE_LENGTH = 160;
const MAX_STRING_LENGTH = 120;
// Events whose presence is itself the alarm; they set span error status so
// the standard error monitors see a wedge without a bespoke query.
const FAILURE_EVENT_PATTERN = /(-failed|-overdue|-stalled|-terminal)$/;

export type TransportJournalEvent = {
  readonly timestamp: string;
  readonly monoMs: number;
  readonly component: string;
  readonly event: string;
  readonly platform: "mac" | "ios";
  readonly clientChannel?: string;
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  /** 12-hex endpoint prefix, matching client journals and iroh-v2 sink rows. */
  readonly endpoint?: string;
  readonly deviceId?: string;
  readonly buildTag?: string;
  readonly attributes?: Readonly<Record<string, string>>;
};

function boundedString(value: unknown, maxLength = MAX_STRING_LENGTH): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) return null;
  return value;
}

/** Validates one client-submitted journal event; null rejects the batch. */
export function parseTransportJournalEvent(value: unknown): TransportJournalEvent | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  const timestamp = boundedString(record.timestamp, 40);
  if (!timestamp || Number.isNaN(Date.parse(timestamp))) return null;
  if (typeof record.monoMs !== "number" || !Number.isFinite(record.monoMs) || record.monoMs < 0) return null;
  const component = boundedString(record.component, 32);
  if (!component || !components.has(component)) return null;
  const event = boundedString(record.event, 48);
  if (!event || !EVENT_PATTERN.test(event)) return null;
  const platform = boundedString(record.platform, 8);
  if (!platform || !platforms.has(platform)) return null;
  const result: {
    -readonly [Key in keyof TransportJournalEvent]: TransportJournalEvent[Key];
  } = {
    timestamp,
    monoMs: Math.floor(record.monoMs),
    component,
    event,
    platform: platform as "mac" | "ios",
  };
  if (record.clientChannel !== undefined) {
    const channel = boundedString(record.clientChannel, 16);
    if (!channel || !channels.has(channel)) return null;
    result.clientChannel = channel;
  }
  for (const key of ["appVersion", "buildNumber", "bundleIdentifier", "osVersion", "deviceId", "buildTag"] as const) {
    if (record[key] === undefined) continue;
    const parsed = boundedString(record[key]);
    if (!parsed) return null;
    result[key] = parsed;
  }
  if (record.endpoint !== undefined) {
    const endpoint = boundedString(record.endpoint, 12);
    if (!endpoint || !ENDPOINT_PATTERN.test(endpoint)) return null;
    result.endpoint = endpoint;
  }
  if (record.attributes !== undefined) {
    if (typeof record.attributes !== "object" || record.attributes === null) return null;
    const entries = Object.entries(record.attributes as Record<string, unknown>);
    if (entries.length > MAX_ATTRIBUTES) return null;
    const attributes: Record<string, string> = {};
    for (const [key, item] of entries) {
      if (!ATTRIBUTE_KEY_PATTERN.test(key)) return null;
      const parsed = boundedString(item, MAX_ATTRIBUTE_VALUE_LENGTH);
      if (parsed === null) return null;
      attributes[key] = parsed;
    }
    result.attributes = attributes;
  }
  return result;
}

/**
 * Emits one span per exported client transport-journal event. The span name
 * is fixed and the component/event live in attributes, so cardinality stays
 * bounded and one query covers the whole credential-renewal pipeline.
 */
export async function emitTransportJournalEvents(
  userId: string,
  batch: readonly TransportJournalEvent[],
): Promise<void> {
  await Promise.all(batch.map((entry) => withSpan(
    "cmux-transport-journal",
    "cmux.transport.journal",
    {
      "cmux.subsystem": "transport-journal",
      "cmux.observation.source": "client",
      "cmux.user_id": userId,
      "cmux.client.channel": entry.clientChannel,
      "cmux.transport.platform": entry.platform,
      "cmux.transport.component": entry.component,
      "cmux.transport.event": entry.event,
      "cmux.transport.occurred_at": entry.timestamp,
      "cmux.transport.mono_ms": entry.monoMs,
      "cmux.device.endpoint": entry.endpoint,
      "cmux.device.id": entry.deviceId,
      "cmux.device.build_tag": entry.buildTag,
      "cmux.transport.app_version": entry.appVersion,
      "cmux.transport.build_number": entry.buildNumber,
      "cmux.transport.bundle_identifier": entry.bundleIdentifier,
      "cmux.transport.os_version": entry.osVersion,
      ...Object.fromEntries(Object.entries(entry.attributes ?? {})
        .map(([key, value]) => [`cmux.transport.attr.${key}`, value])),
    },
    (span) => {
      if (FAILURE_EVENT_PATTERN.test(entry.event)) {
        span.setStatus({ code: SpanStatusCode.ERROR, message: `${entry.component}/${entry.event}` });
      }
    },
  )));
}
