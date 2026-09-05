import { env } from "../../app/env";
import { configLayer, IrohTrustBrokerConfig, type IrohTrustBrokerConfigShape } from "./configCore";

export { IrohTrustBrokerConfig, type IrohTrustBrokerConfigShape } from "./configCore";

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
    deploymentEnvironment: process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "development",
    isVercelDeployment: process.env.VERCEL === "1",
  };
}

export const IrohTrustBrokerConfigLive = configLayer(irohTrustBrokerConfigFromEnv());
