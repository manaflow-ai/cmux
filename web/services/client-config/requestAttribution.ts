/// Low-cardinality request attribution for `/api/client-config`.
///
/// The native apps label every control-plane request with `X-Cmux-*` headers
/// so the route can log one structured line per request. Those logs are the
/// request-volume counter PostHog billing does not provide: PostHog reports
/// only a daily project-wide total, with no client, version, or channel
/// breakdown. Every value is normalized against a fixed allowlist before it
/// reaches a log line, so a hostile caller cannot inject log content or grow
/// cardinality.

export const CLIENT_CONFIG_CLIENT_HEADER = "x-cmux-client";
export const CLIENT_CONFIG_CHANNEL_HEADER = "x-cmux-channel";
export const CLIENT_CONFIG_APP_VERSION_HEADER = "x-cmux-app-version";
export const CLIENT_CONFIG_APP_BUILD_HEADER = "x-cmux-app-build";
export const CLIENT_CONFIG_REFRESH_REASON_HEADER = "x-cmux-refresh-reason";
export const CLIENT_CONFIG_POLL_INTERVAL_HEADER = "x-cmux-poll-interval";

const KNOWN_CLIENTS = new Set(["macos", "ios", "web"]);
const KNOWN_CHANNELS = new Set(["stable", "rc", "nightly", "dev"]);
const KNOWN_REASONS = new Set(["launch", "timer", "foreground", "manual"]);

/// Version and build strings are logged verbatim only when they look like
/// version identifiers; anything else collapses to "invalid".
const VERSION_PATTERN = /^[0-9A-Za-z.+_-]{1,64}$/;

const MAX_POLL_INTERVAL_SECONDS = 7 * 24 * 60 * 60;

export type ClientConfigRequestAttribution = {
  readonly client: string;
  readonly channel: string;
  readonly reason: string;
  readonly appVersion: string;
  readonly appBuild: string;
  readonly pollIntervalSeconds: number | null;
};

export function readClientConfigRequestAttribution(
  headers: Headers,
): ClientConfigRequestAttribution {
  return {
    client: normalizeEnum(headers.get(CLIENT_CONFIG_CLIENT_HEADER), KNOWN_CLIENTS),
    channel: normalizeEnum(headers.get(CLIENT_CONFIG_CHANNEL_HEADER), KNOWN_CHANNELS),
    reason: normalizeEnum(headers.get(CLIENT_CONFIG_REFRESH_REASON_HEADER), KNOWN_REASONS),
    appVersion: normalizeVersion(headers.get(CLIENT_CONFIG_APP_VERSION_HEADER)),
    appBuild: normalizeVersion(headers.get(CLIENT_CONFIG_APP_BUILD_HEADER)),
    pollIntervalSeconds: normalizePollInterval(
      headers.get(CLIENT_CONFIG_POLL_INTERVAL_HEADER),
    ),
  };
}

function normalizeEnum(value: string | null, known: ReadonlySet<string>): string {
  if (value === null) return "unknown";
  const trimmed = value.trim().toLowerCase();
  if (!trimmed) return "unknown";
  return known.has(trimmed) ? trimmed : "other";
}

function normalizeVersion(value: string | null): string {
  if (value === null) return "unknown";
  const trimmed = value.trim();
  if (!trimmed) return "unknown";
  return VERSION_PATTERN.test(trimmed) ? trimmed : "invalid";
}

function normalizePollInterval(value: string | null): number | null {
  if (value === null) return null;
  const parsed = Number.parseInt(value.trim(), 10);
  if (!Number.isSafeInteger(parsed)) return null;
  if (parsed < 0 || parsed > MAX_POLL_INTERVAL_SECONDS) return null;
  return parsed;
}
