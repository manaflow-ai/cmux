import * as Effect from "effect/Effect";

import {
  configuredRelayCatalog,
  relayPolicyPayload,
  relayPolicySigningKey,
  signRelayPolicy,
  type RelayPolicySigningKey,
} from "./catalog";
import {
  assertManagedSelectionExists,
  type RelayCatalog,
  type RelayPolicyPayload,
  type RelayPreference,
} from "./model";
import {
  RelayPreferenceValidationError,
  RelaySigningError,
} from "./errors";
import {
  RelayRepository,
  type RelayPreferenceRecord,
} from "./repository";

export type SignedRelayPolicyResult = {
  readonly policy: string;
  readonly payload: RelayPolicyPayload;
  readonly preference: RelayPreference;
  readonly preferenceRevision: number;
};

export type RelayWorkflowConfig = {
  readonly catalog: RelayCatalog;
  readonly signingKey: RelayPolicySigningKey;
  readonly nowSeconds: number;
  readonly jti?: string;
};

export function productionRelayWorkflowConfig(): RelayWorkflowConfig {
  return {
    catalog: configuredRelayCatalog(),
    signingKey: relayPolicySigningKey(),
    nowSeconds: Math.floor(Date.now() / 1_000),
  };
}

export function signedRelayPolicy(
  accountId: string,
  config: RelayWorkflowConfig,
) {
  return Effect.gen(function* () {
    const repository = yield* RelayRepository;
    yield* repository.acceptCatalog({
      catalog: config.catalog,
      nowSeconds: config.nowSeconds,
    });
    const record = yield* repository.getPreference(accountId);
    const signed = yield* Effect.try({
      try: () => {
        const payload = relayPolicyPayload({
          catalog: config.catalog,
          nowSeconds: config.nowSeconds,
          ...(config.jti ? { jti: config.jti } : {}),
        });
        return {
          payload,
          policy: signRelayPolicy({ payload, signingKey: config.signingKey }),
        };
      },
      catch: (error) => error instanceof RelaySigningError
        ? error
        : new RelaySigningError({ cause: error }),
    });
    return {
      policy: signed.policy,
      payload: signed.payload,
      preference: record.preference,
      preferenceRevision: record.revision,
    } satisfies SignedRelayPolicyResult;
  });
}

export function getRelayPreference(accountId: string) {
  return Effect.gen(function* () {
    const repository = yield* RelayRepository;
    return yield* repository.getPreference(accountId);
  });
}

export function putRelayPreference(input: {
  readonly accountId: string;
  readonly expectedRevision?: number;
  readonly preference: RelayPreference;
  readonly catalog: RelayCatalog;
}) {
  return Effect.gen(function* () {
    yield* Effect.try({
      try: () => assertManagedSelectionExists(input.preference, input.catalog),
      catch: (error) => error instanceof RelayPreferenceValidationError
        ? error
        : new RelayPreferenceValidationError({ code: "invalid_preference" }),
    });
    const repository = yield* RelayRepository;
    return yield* repository.putPreference({
      accountId: input.accountId,
      ...(input.expectedRevision === undefined
        ? {}
        : { expectedRevision: input.expectedRevision }),
      preference: input.preference,
    });
  });
}

export type { RelayPreferenceRecord };
