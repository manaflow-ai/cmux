"use client";

import posthog from "posthog-js";

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

const CLIENT_CONFIG_CACHE_KEY = "cmux.client-config.v1";
const CLIENT_CONFIG_CACHE_TTL_MS = 5 * 60 * 1000;

type StoredClientConfig = {
  readonly requestBody: string;
  readonly expiresAt: number;
  readonly config: ClientConfig;
};

// Share one short-lived result across flag consumers and full navigations.
// Key by the complete evaluation so identity or targeting changes miss the
// cache. Storage is optional; memory still handles storage-disabled browsers.
let cachedClientConfig: StoredClientConfig | undefined;
const pendingClientConfigs = new Map<string, Promise<ClientConfig>>();

type PostHogWithFlagContext = typeof posthog & {
  readonly config?: {
    readonly evaluation_contexts?: unknown;
    readonly evaluation_environments?: unknown;
  };
  readonly getAnonymousId?: () => unknown;
  readonly featureFlags?: {
    readonly $anon_distinct_id?: unknown;
  };
  readonly persistence?: {
    readonly get_initial_props?: () => unknown;
  };
};

export async function getClientConfig(
  options: { readonly distinctId?: string; readonly context?: ClientConfigEvaluationContext } = {},
): Promise<ClientConfig> {
  const requestBody = JSON.stringify({
    distinctId: options.distinctId ?? getPostHogDistinctId(),
    context: options.context ?? getPostHogEvaluationContext(),
  });
  const cached = readStoredClientConfig(requestBody);
  if (cached) return cached;

  const pending = pendingClientConfigs.get(requestBody);
  if (pending) return pending;

  const request = fetch("/api/client-config", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: requestBody,
    cache: "no-store",
  })
    .then(async (response) => {
      if (!response.ok) {
        throw new Error("client_config_unavailable");
      }
      const config = await response.json() as ClientConfig;
      if (isCacheableClientConfig(config)) writeStoredClientConfig(requestBody, config);
      return config;
    })
    .finally(() => {
      pendingClientConfigs.delete(requestBody);
    });
  pendingClientConfigs.set(requestBody, request);
  return request;
}

function readStoredClientConfig(requestBody: string): ClientConfig | undefined {
  if (isFreshClientConfig(cachedClientConfig, requestBody)) return cachedClientConfig.config;
  cachedClientConfig = undefined;
  const storage = clientConfigStorage();
  if (!storage) return undefined;

  try {
    const raw = storage.getItem(CLIENT_CONFIG_CACHE_KEY);
    if (!raw) return undefined;
    const stored = JSON.parse(raw) as Partial<StoredClientConfig>;
    if (!isFreshClientConfig(stored, requestBody)) {
      storage.removeItem(CLIENT_CONFIG_CACHE_KEY);
      return undefined;
    }
    cachedClientConfig = stored;
    return stored.config;
  } catch {
    return undefined;
  }
}

function isFreshClientConfig(
  value: Partial<StoredClientConfig> | undefined,
  requestBody: string,
): value is StoredClientConfig {
  return Boolean(value && value.requestBody === requestBody &&
    typeof value.expiresAt === "number" && value.expiresAt > Date.now() &&
    isCacheableClientConfig(value.config));
}

function isCacheableClientConfig(value: unknown): value is ClientConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const config = value as Partial<ClientConfig>;
  return config.errorsWhileComputingFlags === false &&
    isRecord(config.featureFlags) &&
    Object.values(config.featureFlags).every((flag) => typeof flag === "boolean" || typeof flag === "string") &&
    isRecord(config.featureFlagPayloads);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function writeStoredClientConfig(requestBody: string, config: ClientConfig): void {
  const stored: StoredClientConfig = {
    requestBody,
    expiresAt: Date.now() + CLIENT_CONFIG_CACHE_TTL_MS,
    config,
  };
  cachedClientConfig = stored;
  const storage = clientConfigStorage();
  if (!storage) return;

  try {
    storage.setItem(CLIENT_CONFIG_CACHE_KEY, JSON.stringify(stored));
  } catch {
    // Storage is an optional optimization. Private browsing and quota errors
    // must leave the network-backed path working.
  }
}

function clientConfigStorage(): Storage | undefined {
  if (typeof window === "undefined") return undefined;
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

function getPostHogEvaluationContext(): ClientConfigEvaluationContext {
  return {
    groups: getPostHogGroups(),
    personProperties: getPostHogPersonProperties(),
    groupProperties: getPostHogRecordProperty("$stored_group_properties"),
    anonDistinctId: getPostHogAnonDistinctId(),
    deviceId: getPostHogStringProperty("$device_id"),
    timezone: getBrowserTimezone(),
    evaluationContexts: getPostHogEvaluationContexts(),
  };
}

function getPostHogDistinctId(): string {
  try {
    const distinctId = posthog.get_distinct_id();
    if (typeof distinctId === "string" && distinctId.trim()) return distinctId;
  } catch {
    return "anonymous";
  }
  return "anonymous";
}

function getPostHogGroups(): Record<string, unknown> {
  try {
    const groups = posthog.getGroups();
    if (groups && typeof groups === "object" && !Array.isArray(groups)) {
      return { ...(groups as Record<string, unknown>) };
    }
  } catch {
    return {};
  }
  return {};
}

function getPostHogPersonProperties(): Record<string, unknown> {
  return {
    ...getPostHogInitialProps(),
    ...getPostHogRecordProperty("$stored_person_properties"),
  };
}

function getPostHogInitialProps(): Record<string, unknown> {
  const client = posthog as PostHogWithFlagContext;
  try {
    const value = client.persistence?.get_initial_props?.();
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return { ...(value as Record<string, unknown>) };
    }
  } catch {
    return {};
  }
  return {};
}

function getPostHogRecordProperty(key: string): Record<string, unknown> {
  try {
    const value = posthog.get_property(key);
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return { ...(value as Record<string, unknown>) };
    }
  } catch {
    return {};
  }
  return {};
}

function getPostHogStringProperty(key: string): string | undefined {
  try {
    const value = posthog.get_property(key);
    return typeof value === "string" && value.trim() ? value : undefined;
  } catch {
    return undefined;
  }
}

function getPostHogAnonDistinctId(): string | undefined {
  const client = posthog as PostHogWithFlagContext;
  try {
    const value = client.getAnonymousId?.();
    if (typeof value === "string" && value.trim()) return value;
  } catch {
    return getPersistedPostHogAnonDistinctId(client);
  }
  return getPersistedPostHogAnonDistinctId(client);
}

function getPersistedPostHogAnonDistinctId(client: PostHogWithFlagContext): string | undefined {
  const value = getPostHogStringProperty("anonymous_id") ??
    getPostHogStringProperty("$anon_distinct_id") ??
    client.featureFlags?.$anon_distinct_id;
  return typeof value === "string" && value.trim() ? value : undefined;
}

function getBrowserTimezone(): string | undefined {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    return undefined;
  }
}

function getPostHogEvaluationContexts(): string[] | undefined {
  const client = posthog as PostHogWithFlagContext;
  const value = client.config?.evaluation_contexts ?? client.config?.evaluation_environments;
  if (!Array.isArray(value)) return undefined;
  const contexts = value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter(Boolean);
  return contexts.length ? contexts : undefined;
}
