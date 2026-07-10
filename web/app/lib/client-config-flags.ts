"use client";

import { useEffect, useState } from "react";

import { getClientConfig, type ClientConfig, type ClientConfigFlagValue } from "./client-config";

export type ClientConfigFlagDefinition<Value> = {
  readonly key: string;
  readonly defaultValue: Value;
  readonly read: (config: ClientConfig) => Value;
};

export type ClientConfigPayloadDefinition<Value> = {
  readonly key: string;
  readonly defaultValue: Value | undefined;
  readonly read: (config: ClientConfig) => Value | undefined;
};

export function booleanClientConfigFlag(
  key: string,
  defaultValue = false,
): ClientConfigFlagDefinition<boolean> {
  return {
    key,
    defaultValue,
    read(config) {
      const value = config.featureFlags[key];
      return typeof value === "boolean" ? value : defaultValue;
    },
  };
}

export function variantClientConfigFlag(
  key: string,
  defaultValue?: string,
): ClientConfigFlagDefinition<string | undefined> {
  return {
    key,
    defaultValue,
    read(config) {
      const value = config.featureFlags[key];
      return typeof value === "string" ? value : defaultValue;
    },
  };
}

export function payloadClientConfigFlag<Value>(
  key: string,
  decode: (payload: unknown) => Value | undefined,
  defaultValue?: Value,
): ClientConfigPayloadDefinition<Value> {
  return {
    key,
    defaultValue,
    read(config) {
      const value = decode(config.featureFlagPayloads[key]);
      return value === undefined ? defaultValue : value;
    },
  };
}

export function getClientConfigValue<Value>(
  config: ClientConfig,
  flag: ClientConfigFlagDefinition<Value>,
): Value {
  return flag.read(config);
}

export async function loadClientConfigValue<Value>(
  flag: ClientConfigFlagDefinition<Value>,
  options: Parameters<typeof getClientConfig>[0] = {},
): Promise<Value> {
  return flag.read(await getClientConfig(options));
}

export function rawClientConfigFlagValue(
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

// One config fetch per page load, shared by every flag consumer; a failed
// fetch clears the cache so a later mount can retry.
let cachedClientConfig: Promise<ClientConfig> | null = null;

export function useClientConfigFlag(key: string): ClientConfigFlagValue | undefined {
  const [value, setValue] = useState<ClientConfigFlagValue | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    cachedClientConfig ??= getClientConfig();
    cachedClientConfig
      .then((config) => {
        if (!cancelled) setValue(rawClientConfigFlagValue(config, key));
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

export const clientConfigFlags = {
  cmuxForWindows: booleanClientConfigFlag("cmux-for-windows"),
  cmuxForLinux: booleanClientConfigFlag("cmux-for-linux"),
  cmuxForAndroid: booleanClientConfigFlag("cmux-for-android"),
  proUpgradeUIEnabledRelease: booleanClientConfigFlag("pro-upgrade-ui-enabled-release"),
  mobileConnectButtonEnabledRelease: booleanClientConfigFlag("mobile-connect-button-enabled-release"),
} as const;
