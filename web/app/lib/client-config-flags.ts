"use client";

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

export const clientConfigFlags = {
  cmuxForWindows: booleanClientConfigFlag("cmux-for-windows"),
  cmuxForLinux: booleanClientConfigFlag("cmux-for-linux"),
  cmuxForAndroid: booleanClientConfigFlag("cmux-for-android"),
  proUpgradeUIEnabledRelease: booleanClientConfigFlag("pro-upgrade-ui-enabled-release"),
  mobileConnectButtonEnabledRelease: booleanClientConfigFlag("mobile-connect-button-enabled-release"),
} as const;
