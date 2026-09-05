import * as Context from "effect/Context";
import * as Layer from "effect/Layer";

/** Runtime-neutral configuration required by the Iroh trust broker. */
export type IrohTrustBrokerConfigShape = {
  readonly lanDiscoverySecretBase64?: string;
  readonly accountSubjectSecretBase64?: string;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
  readonly grantVerificationKeysJson?: string;
  readonly relayMinterUrl?: string;
  readonly relayMinterHmacSecretBase64?: string;
  readonly relayMinterInsecureLoopbackOptIn: boolean;
  readonly deploymentEnvironment: string;
  readonly isVercelDeployment: boolean;
};

export class IrohTrustBrokerConfig extends Context.Tag("cmux/IrohTrustBrokerConfig")<
  IrohTrustBrokerConfig,
  IrohTrustBrokerConfigShape
>() {}

export function configLayer(
  config: IrohTrustBrokerConfigShape,
): Layer.Layer<IrohTrustBrokerConfig> {
  return Layer.succeed(IrohTrustBrokerConfig, config);
}
