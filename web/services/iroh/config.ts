import * as Context from "effect/Context";
import * as Layer from "effect/Layer";
import { env } from "../../app/env";

export type IrohTrustBrokerConfigShape = {
  readonly lanDiscoverySecretBase64?: string;
  readonly accountSubjectSecretBase64?: string;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
  readonly grantVerificationKeysJson?: string;
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
  };
}

export const IrohTrustBrokerConfigLive = Layer.succeed(
  IrohTrustBrokerConfig,
  irohTrustBrokerConfigFromEnv(),
);

