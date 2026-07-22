import { POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";

export const MAX_CLIENT_CONFIG_REQUEST_BYTES = 16 * 1024;
export const CLIENT_CONFIG_FLAGS_TIMEOUT_MS = 4_000;
export const POSTHOG_FLAGS_HOST = (process.env.POSTHOG_FLAGS_HOST ?? "https://us.i.posthog.com").replace(/\/$/, "");

export type ClientConfigFlagValue = boolean | string;

export type ClientConfig = {
  readonly featureFlags: Record<string, ClientConfigFlagValue>;
  readonly featureFlagPayloads: Record<string, unknown>;
  readonly errorsWhileComputingFlags: boolean;
  readonly requestId?: string;
};

export type ClientConfigEvaluationContext = {
  readonly groups?: Record<string, unknown>;
  readonly personProperties?: Record<string, unknown>;
  readonly groupProperties?: Record<string, unknown>;
  readonly anonDistinctId?: string;
  readonly deviceId?: string;
  readonly timezone?: string;
  readonly evaluationContexts?: readonly string[];
};

export function normalizeDistinctId(value: unknown): string {
  if (typeof value !== "string") return "anonymous";
  const trimmed = value.trim();
  if (!trimmed) return "anonymous";
  return trimmed.slice(0, 200);
}

export function postHogFlagsUrl(): string {
  return `${POSTHOG_FLAGS_HOST}/flags/?v=2&ip=0`;
}

export function postHogFlagsBody(distinctId: string, context: ClientConfigEvaluationContext = {}): string {
  const body: Record<string, unknown> = {
    token: POSTHOG_PROJECT_KEY,
    distinct_id: distinctId,
    groups: context.groups ?? {},
    person_properties: context.personProperties ?? {},
    group_properties: context.groupProperties ?? {},
  };
  if (context.anonDistinctId) body.$anon_distinct_id = context.anonDistinctId;
  if (context.deviceId) body.$device_id = context.deviceId;
  if (context.timezone) body.timezone = context.timezone;
  if (context.evaluationContexts?.length) body.evaluation_contexts = context.evaluationContexts;
  return JSON.stringify(body);
}

export function normalizeClientConfigEvaluationContext(value: unknown): ClientConfigEvaluationContext {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const record = value as Record<string, unknown>;
  return {
    groups: normalizePayloads(record.groups),
    personProperties: normalizePayloads(record.personProperties),
    groupProperties: normalizePayloads(record.groupProperties),
    anonDistinctId: normalizeOptionalString(record.anonDistinctId),
    deviceId: normalizeOptionalString(record.deviceId),
    timezone: normalizeOptionalString(record.timezone),
    evaluationContexts: normalizeStringArray(record.evaluationContexts),
  };
}

export function normalizePostHogFlagsResponse(body: Record<string, unknown>): ClientConfig {
  const featureFlags: Record<string, ClientConfigFlagValue> = {};
  const legacyPayloads = normalizeFeatureFlagPayloads(body.featureFlagPayloads);
  const featureFlagPayloads = { ...legacyPayloads };
  const suppressedPayloadKeys = new Set<string>();

  const legacyFeatureFlags = body.featureFlags;
  if (legacyFeatureFlags && typeof legacyFeatureFlags === "object" && !Array.isArray(legacyFeatureFlags)) {
    for (const [key, value] of Object.entries(legacyFeatureFlags)) {
      if (typeof value === "boolean" || typeof value === "string") {
        featureFlags[key] = value;
      }
    }
  }

  const detailedFlags = body.flags;
  if (detailedFlags && typeof detailedFlags === "object" && !Array.isArray(detailedFlags)) {
    for (const [key, value] of Object.entries(detailedFlags)) {
      if (isFailedDetailedFlag(value)) {
        delete featureFlags[key];
        delete featureFlagPayloads[key];
        suppressedPayloadKeys.add(key);
        continue;
      }
      const normalized = normalizeDetailedFlag(value);
      if (normalized !== undefined) {
        featureFlags[key] = normalized;
        if (normalized === false) {
          delete featureFlagPayloads[key];
          suppressedPayloadKeys.add(key);
        }
      }
      const payload = payloadFromDetailedFlag(value, normalized);
      if (payload !== undefined && featureFlagPayloads[key] === undefined) {
        featureFlagPayloads[key] = payload;
      }
    }
  }

  for (const key of Object.keys(legacyPayloads)) {
    if (featureFlags[key] === undefined && !suppressedPayloadKeys.has(key)) {
      featureFlags[key] = true;
    }
    if (featureFlags[key] === false || suppressedPayloadKeys.has(key)) {
      delete featureFlagPayloads[key];
    }
  }

  const config: ClientConfig = {
    featureFlags,
    featureFlagPayloads,
    errorsWhileComputingFlags: body.errorsWhileComputingFlags === true,
  };
  if (typeof body.requestId === "string") {
    return { ...config, requestId: body.requestId };
  }
  return config;
}

export function isPostHogFlagsResponseAvailable(body: Record<string, unknown>): boolean {
  if (isFeatureFlagsQuotaLimited(body.quotaLimited)) return false;
  return isFlagsRecord(body.featureFlags) || isFlagsRecord(body.flags) || isFlagsRecord(body.featureFlagPayloads);
}

function isFeatureFlagsQuotaLimited(value: unknown): boolean {
  if (value === true) return true;
  return Array.isArray(value) && value.includes("feature_flags");
}

function isFlagsRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function normalizePayloads(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return { ...(value as Record<string, unknown>) };
}

function normalizeFeatureFlagPayloads(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const payloads: Record<string, unknown> = {};
  for (const [key, payload] of Object.entries(value)) {
    // Match posthog-js: payload values are already JSON values, and string
    // payloads remain strings instead of being parsed opportunistically.
    payloads[key] = payload;
  }
  return payloads;
}

function normalizeOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, 500) : undefined;
}

function normalizeStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const strings = value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 20);
  return strings.length ? strings : undefined;
}

function normalizeDetailedFlag(value: unknown): ClientConfigFlagValue | undefined {
  if (typeof value === "boolean" || typeof value === "string") return value;
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;

  const record = value as Record<string, unknown>;
  if (record.enabled === false) return false;
  if (typeof record.variant === "string") return record.variant;
  if (typeof record.enabled === "boolean") return record.enabled;
  return undefined;
}

function isFailedDetailedFlag(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return (value as Record<string, unknown>).failed === true;
}

function payloadFromDetailedFlag(value: unknown, flagValue: ClientConfigFlagValue | undefined): unknown {
  if (flagValue === undefined || flagValue === false) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const metadata = (value as Record<string, unknown>).metadata;
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) return undefined;
  // posthog-js copies metadata.payload through without JSON.parse; preserve
  // string payloads so free-text payloads do not change type.
  return (metadata as Record<string, unknown>).payload;
}
