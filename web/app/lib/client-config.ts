"use client";

import posthog from "posthog-js";
import { useEffect, useState } from "react";

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
  const response = await fetch("/api/client-config", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      distinctId: options.distinctId ?? getPostHogDistinctId(),
      context: options.context ?? getPostHogEvaluationContext(),
    }),
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error("client_config_unavailable");
  }
  return await response.json() as ClientConfig;
}

export function getClientConfigFlag(
  config: ClientConfig,
  key: string,
): ClientConfigFlagValue | undefined {
  return config.featureFlags[key];
}

export function isClientConfigFlagEnabled(
  value: ClientConfigFlagValue | undefined,
  fallback: boolean,
): boolean {
  if (value === undefined) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 && normalized !== "false";
}

let cachedClientConfig: Promise<ClientConfig> | null = null;

export function useClientConfigFlag(key: string): ClientConfigFlagValue | undefined {
  const [value, setValue] = useState<ClientConfigFlagValue | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    cachedClientConfig ??= getClientConfig();
    cachedClientConfig
      .then((config) => {
        if (!cancelled) setValue(getClientConfigFlag(config, key));
      })
      .catch(() => {
        cachedClientConfig = null;
        if (!cancelled) setValue(undefined);
      });
    return () => {
      cancelled = true;
    };
  }, [key]);

  return value;
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
