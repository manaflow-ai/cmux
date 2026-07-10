import * as Context from "effect/Context";
import * as Layer from "effect/Layer";
import { env } from "../../app/env";

export type IrohTrustBrokerConfigShape = {
  readonly lanDiscoverySecretBase64?: string;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
  readonly grantVerificationKeysJson?: string;
  readonly relayMinterUrl?: string;
  readonly relayMinterHmacSecretBase64?: string;
  readonly rateLimitId?: string;
  readonly deviceLimitOverrideEnabled: boolean;
  readonly deviceLimitOverrideUserIds: ReadonlySet<string>;
  readonly deviceLimitOverrideEnvironments: ReadonlySet<string>;
  readonly deploymentEnvironment: string;
};

export class IrohTrustBrokerConfig extends Context.Tag("cmux/IrohTrustBrokerConfig")<
  IrohTrustBrokerConfig,
  IrohTrustBrokerConfigShape
>() {}

export function irohTrustBrokerConfigFromEnv(): IrohTrustBrokerConfigShape {
  return {
    lanDiscoverySecretBase64: env.CMUX_IROH_LAN_DISCOVERY_SECRET_B64,
    grantSigningPrivateKeyPem: env.CMUX_IROH_GRANT_SIGNING_KEY_P8,
    grantSigningKid: env.CMUX_IROH_GRANT_SIGNING_KID,
    grantVerificationKeysJson: env.CMUX_IROH_GRANT_VERIFY_KEYS_JSON,
    relayMinterUrl: env.CMUX_IROH_MINT_URL,
    relayMinterHmacSecretBase64: env.CMUX_IROH_MINT_HMAC_SECRET_B64,
    rateLimitId: env.CMUX_IROH_RATE_LIMIT_ID,
    deviceLimitOverrideEnabled: env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENABLED === "1",
    deviceLimitOverrideUserIds: csvSet(env.CMUX_IROH_DEV_BINDING_OVERRIDE_USER_IDS),
    deviceLimitOverrideEnvironments: csvSet(env.CMUX_IROH_DEV_BINDING_OVERRIDE_ENVIRONMENTS),
    deploymentEnvironment: process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "development",
  };
}

export function deviceLimitOverrideAllowed(
  config: IrohTrustBrokerConfigShape,
  authenticatedUserId: string,
): boolean {
  if (!config.deviceLimitOverrideEnabled) return false;
  return config.deviceLimitOverrideUserIds.has(authenticatedUserId) &&
    config.deviceLimitOverrideEnvironments.has(config.deploymentEnvironment);
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
