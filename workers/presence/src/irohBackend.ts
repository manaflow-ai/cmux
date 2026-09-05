/** Runtime-neutral Iroh backend assembled inside the account Durable Object. */
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { KeyObject } from "node:crypto";
import {
  makeConnectivityAuthority,
  type ConnectivityAuthorityShape,
} from "../../../web/services/connectivity/authority";
import {
  configuredRelayCatalog,
  relayPolicySigningKey,
  type RelayPolicySigningKey,
} from "../../../web/services/relay/catalog";
import { RelayConfigurationError } from "../../../web/services/relay/errors";
import { relaySigningKey as readRelaySigningKey } from "../../../web/services/relay/token";
import {
  makeIrohRepository,
  type IrohRepositoryShape,
} from "../../../web/services/iroh/repository";
import {
  makeIrohRelayMinter,
} from "../../../web/services/iroh/relayMinter";
import {
  makeIrohTrustBroker,
  type IrohTrustBrokerShape,
} from "../../../web/services/iroh/trustBroker";
import {
  makeRelayRepository,
  RelayRepository,
  type RelayRepositoryShape,
} from "../../../web/services/relay/repository";
import {
  type IrohTrustBrokerConfigShape,
} from "../../../web/services/iroh/configCore";
import {
  mintManagedRelayCredentials,
  type ManagedRelayCredentialGrant,
} from "../../../web/services/relay/token";
import { signedRelayPolicy, type SignedRelayPolicyResult } from "../../../web/services/relay/workflows";
import { cloudDb, type HyperdriveBindingLike } from "./hyperdriveDb";

export type IrohWorkerEnvironment = {
  readonly HYPERDRIVE?: HyperdriveBindingLike;
  readonly CMUX_IROH_LAN_DISCOVERY_SECRET_B64?: string;
  readonly CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64?: string;
  readonly CMUX_IROH_GRANT_SIGNING_KEY_P8?: string;
  readonly CMUX_IROH_GRANT_SIGNING_KID?: string;
  readonly CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON?: string;
  readonly CMUX_IROH_MINT_URL?: string;
  readonly CMUX_IROH_MINT_HMAC_SECRET_B64?: string;
  readonly CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER?: string;
  readonly CMUX_RELAY_POLICY_KEY_ID?: string;
  readonly CMUX_RELAY_POLICY_PRIVATE_KEY_PEM?: string;
  readonly CMUX_RELAY_JWT_PRIVATE_KEY_PEM?: string;
};

export type WorkerIrohBackend = {
  readonly broker: IrohTrustBrokerShape;
  readonly connectivity: ConnectivityAuthorityShape;
  readonly repository: IrohRepositoryShape;
  readonly relayRepository: RelayRepositoryShape;
  readonly config: IrohTrustBrokerConfigShape;
  readonly relayPolicySigningKey: RelayPolicySigningKey | null;
  readonly relayCredentialSigningKey: KeyObject | null;
};

export function irohConfigFromWorkerEnv(
  env: IrohWorkerEnvironment,
): IrohTrustBrokerConfigShape {
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
    deploymentEnvironment: "production",
    isVercelDeployment: false,
  };
}

/**
 * Build once per account DO. The DB provider is deliberately injected into
 * both repositories so no Vercel/AWS client or process environment reaches a
 * Worker bundle. Row-backed transaction fences are used because Hyperdrive
 * does not implement PostgreSQL advisory locks.
 */
export function makeWorkerIrohBackend(
  env: IrohWorkerEnvironment,
): WorkerIrohBackend {
  const config = irohConfigFromWorkerEnv(env);
  // The repository invokes this provider inside each transaction. That keeps
  // the postgres.js client request-scoped while Hyperdrive pools the origin
  // connection underneath it.
  const dbProvider = () => cloudDb(env.HYPERDRIVE);
  const repository = makeIrohRepository(dbProvider as never, { lockMode: "row" });
  const relayRepository = makeRelayRepository(dbProvider as never, { lockMode: "row" });
  const relayMinter = makeIrohRelayMinter(config);
  const broker = makeIrohTrustBroker(
    repository,
    relayMinter,
    config,
    relayRepository,
  );
  let policyKey: RelayPolicySigningKey | null = null;
  try {
    policyKey = relayPolicySigningKey({
      CMUX_RELAY_POLICY_KEY_ID: env.CMUX_RELAY_POLICY_KEY_ID,
      CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: env.CMUX_RELAY_POLICY_PRIVATE_KEY_PEM,
    });
  } catch {
    // Relay policy issuance is optional for registration/discovery. Keep the
    // backend usable for those operations and let the relay-token route return
    // its typed 503 configuration response when the key is actually needed.
  }
  return {
    broker,
    connectivity: makeConnectivityAuthority(broker),
    repository,
    relayRepository,
    config,
    relayPolicySigningKey: policyKey,
    relayCredentialSigningKey: readRelaySigningKey({
      CMUX_RELAY_JWT_PRIVATE_KEY_PEM: env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM,
    }),
  };
}

export async function runWorkerEffect<A, E>(program: Effect.Effect<A, E>): Promise<A> {
  const result = await Effect.runPromise(Effect.either(program));
  if (result._tag === "Left") throw result.left;
  return result.right;
}

export async function makeSignedRelayPolicy(
  backend: WorkerIrohBackend,
  accountId: string,
  nowSeconds: number,
): Promise<SignedRelayPolicyResult> {
  const catalog = configuredRelayCatalog();
  if (!backend.relayPolicySigningKey) {
    // Keep the error class produced by the workflow so the HTTP mapper returns
    // the same 503 contract as the web route.
    throw new RelayConfigurationError({ code: "signing_key_not_configured" });
  }
  return await runWorkerEffect(
    signedRelayPolicy(accountId, {
      catalog,
      signingKey: backend.relayPolicySigningKey,
      nowSeconds,
    }).pipe(
      Effect.provide(Layer.succeed(RelayRepository, backend.relayRepository)),
    ),
  );
}

export function issueManagedRelayCredentials(input: {
  readonly backend: WorkerIrohBackend;
  readonly accountId: string;
  readonly endpointId: string;
  readonly relayUrls: readonly string[];
  readonly nowSeconds: number;
}): readonly ManagedRelayCredentialGrant[] | undefined {
  const key = input.backend.relayCredentialSigningKey;
  if (!key) return undefined;
  // The policy key and relay credential key are intentionally separate config
  // values in production. The token helper needs the raw private key object,
  // so the policy key is used only when the dedicated credential key is absent
  // in this first Worker cutover. Operators can set the same Ed25519 key under
  // both names during migration.
  return mintManagedRelayCredentials({
    sub: input.accountId,
    endpointId: input.endpointId,
    relayUrls: input.relayUrls,
    key,
    nowSeconds: input.nowSeconds,
  });
}
