import * as Context from "effect/Context";
import * as Layer from "effect/Layer";
import { env } from "../../app/env";

export const DEFAULT_IROH_ACCOUNT_BINDING_LIMIT = 32;
export const DEFAULT_IROH_DEVICE_BINDING_LIMIT = 8;
export const DEFAULT_IROH_DEV_ACCOUNT_BINDING_LIMIT = 256;
export const DEFAULT_IROH_DEV_DEVICE_BINDING_LIMIT = 128;
export const DEFAULT_IROH_DEV_BINDING_STALE_AFTER_MS = 24 * 60 * 60 * 1_000;
const MAX_IROH_CONFIGURED_BINDING_LIMIT = 4_096;

export type IrohBindingQuota = {
  readonly account: number;
  readonly device: number;
  readonly baselineDevice: number;
  readonly staleAfterMs: number | null;
};

export type IrohChallengeQuota = {
  readonly account: number;
  readonly deviceInstance: number;
  readonly outstanding: number;
};

export type IrohTrustBrokerConfigShape = {
  readonly lanDiscoverySecretBase64?: string;
  readonly accountSubjectSecretBase64?: string;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
  readonly grantVerificationKeysJson?: string;
  readonly relayMinterUrl?: string;
  readonly relayMinterHmacSecretBase64?: string;
  readonly relayMinterInsecureLoopbackOptIn: boolean;
  readonly rateLimitId?: string;
  readonly deviceLimitOverrideEnabled: boolean;
  readonly deviceLimitOverrideUserIds: ReadonlySet<string>;
  readonly deviceLimitOverrideEnvironments: ReadonlySet<string>;
  readonly developmentAccountBindingLimit: number;
  readonly developmentDeviceBindingLimit: number;
  readonly deploymentEnvironment: string;
  readonly isVercelDeployment: boolean;
};

export class IrohTrustBrokerConfig extends Context.Tag("cmux/IrohTrustBrokerConfig")<
  IrohTrustBrokerConfig,
  IrohTrustBrokerConfigShape
>() {}

export function irohTrustBrokerConfigFromEnv(): IrohTrustBrokerConfigShape {
  return {
    lanDiscoverySecretBase64: env.CMUX_IROH_LAN_DISCOVERY_SECRET_B64,
    accountSubjectSecretBase64: env.CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64,
    grantSigningPrivateKeyPem: env.CMUX_IROH_GRANT_SIGNING_KEY_P8,
    grantSigningKid: env.CMUX_IROH_GRANT_SIGNING_KID,
    grantVerificationKeysJson: env.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON,
    relayMinterUrl: env.CMUX_IROH_MINT_URL,
    relayMinterHmacSecretBase64: env.CMUX_IROH_MINT_HMAC_SECRET_B64,
    relayMinterInsecureLoopbackOptIn:
      env.CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER === "1",
    rateLimitId: env.CMUX_IROH_RATE_LIMIT_ID,
    deviceLimitOverrideEnabled: env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENABLED === "1",
    deviceLimitOverrideUserIds: csvSet(env.CMUX_IROH_DEV_BINDING_OVERRIDE_USER_IDS),
    deviceLimitOverrideEnvironments: csvSet(env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENVIRONMENTS),
    developmentAccountBindingLimit: positiveLimit(
      env.CMUX_IROH_DEV_BINDING_ACCOUNT_LIMIT,
      DEFAULT_IROH_DEV_ACCOUNT_BINDING_LIMIT,
    ),
    developmentDeviceBindingLimit: positiveLimit(
      env.CMUX_IROH_DEV_BINDING_DEVICE_LIMIT,
      DEFAULT_IROH_DEV_DEVICE_BINDING_LIMIT,
    ),
    deploymentEnvironment: process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "development",
    isVercelDeployment: process.env.VERCEL === "1",
  };
}

export function developmentBindingQuotaAllowed(
  config: IrohTrustBrokerConfigShape,
  authenticatedUserId: string,
): boolean {
  if (!config.deviceLimitOverrideEnabled) return false;
  return config.deviceLimitOverrideUserIds.has(authenticatedUserId) &&
    config.deviceLimitOverrideEnvironments.has(config.deploymentEnvironment);
}

export function bindingQuotaForUser(
  config: IrohTrustBrokerConfigShape,
  authenticatedUserId: string,
): IrohBindingQuota {
  if (!developmentBindingQuotaAllowed(config, authenticatedUserId)) {
    return {
      account: DEFAULT_IROH_ACCOUNT_BINDING_LIMIT,
      device: DEFAULT_IROH_DEVICE_BINDING_LIMIT,
      baselineDevice: DEFAULT_IROH_DEVICE_BINDING_LIMIT,
      staleAfterMs: null,
    };
  }
  return {
    account: config.developmentAccountBindingLimit,
    device: Math.min(
      config.developmentDeviceBindingLimit,
      config.developmentAccountBindingLimit,
    ),
    baselineDevice: DEFAULT_IROH_DEVICE_BINDING_LIMIT,
    staleAfterMs: DEFAULT_IROH_DEV_BINDING_STALE_AFTER_MS,
  };
}

export function challengeQuotaForUser(
  config: IrohTrustBrokerConfigShape,
  authenticatedUserId: string,
): IrohChallengeQuota {
  if (!developmentBindingQuotaAllowed(config, authenticatedUserId)) {
    return { account: 120, deviceInstance: 6, outstanding: 32 };
  }
  return {
    // Give every allowed dev binding the normal per-instance launch budget,
    // while retaining one bounded account fence against a runaway client.
    account: Math.max(
      120,
      Math.min(
        MAX_IROH_CONFIGURED_BINDING_LIMIT,
        config.developmentAccountBindingLimit * DEFAULT_IROH_DEVICE_BINDING_LIMIT,
      ),
    ),
    deviceInstance: Math.max(6, config.developmentDeviceBindingLimit),
    outstanding: Math.max(32, config.developmentAccountBindingLimit),
  };
}

export const IrohTrustBrokerConfigLive = Layer.succeed(
  IrohTrustBrokerConfig,
  irohTrustBrokerConfigFromEnv(),
);

function csvSet(value: string | undefined): ReadonlySet<string> {
  return new Set(
    value?.split(",").map((entry) => entry.trim()).filter(Boolean) ?? [],
  );
}

function positiveLimit(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) &&
      parsed > 0 &&
      parsed <= MAX_IROH_CONFIGURED_BINDING_LIMIT
    ? parsed
    : fallback;
}
