import { randomBytes, randomUUID } from "node:crypto";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  assertCurrentSigningKey,
  deriveAccountSubject,
  deriveLanRendezvousKey,
  hashesEqual,
  nonceHash,
  parseVerificationKeys,
  signEndpointAttestation,
  signPairGrant,
  verifyEndpointAttestation,
  verifyEndpointRegistrationSignature,
  verifyPairGrant,
  type EndpointAttestationClaims,
  type PairGrantClaims,
  type PairGrantPeer,
} from "./crypto";
import {
  bindingQuotaForUser,
  challengeQuotaForUser,
  IrohTrustBrokerConfig,
  IrohTrustBrokerConfigLive,
  type IrohTrustBrokerConfigShape,
} from "./config";
import {
  IrohConflictError,
  IrohConfigurationError,
  IrohDatabaseError,
  IrohForbiddenError,
  IrohInvalidInputError,
  IrohNotFoundError,
  type IrohExpectedError,
} from "./errors";
import {
  IROH_ALPN,
  IROH_CHALLENGE_LIFETIME_MS,
  IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS,
  IROH_ENDPOINT_ATTESTATION_SCOPE,
  IROH_ENDPOINT_ATTESTATION_VERSION,
  IROH_PAIR_GRANT_LIFETIME_SECONDS,
  IROH_PAIR_SCOPE,
  IROH_RELAY_TOKEN_LIFETIME_SECONDS,
  IROH_RELAY_TOKEN_REFRESH_SECONDS,
  assertChallengeMatchesPayload,
  decodeRegistrationPayload,
  parseBindingIdBody,
  parseChallengeRequest,
  parseIrohPathHint,
  parsePairGrantRequest,
  parseRegisterRequest,
  sha256,
  type IrohPathHint,
} from "./model";
import {
  IrohRepository,
  IrohRepositoryLive,
  type IrohBindingRecord,
  type IrohRepositoryShape,
} from "./repository";
import {
  IrohRelayMinter,
  IrohRelayMinterLive,
  type IrohRelayMinterShape,
} from "./relayMinter";
import {
  defaultRelayPreference,
  type RelayPreference,
} from "../relay/model";
import {
  RelayRepository,
  RelayRepositoryLive,
  type RelayRepositoryShape,
} from "../relay/repository";
import {
  MANAGED_RELAY_URLS,
  accountPrivateIrohPathHints,
} from "./publicationPolicy";

export type IrohTrustBrokerShape = {
  readonly issueChallenge: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly register: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly discover: (
    userId: string,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly revoke: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly issuePairGrant: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly issueEndpointAttestation: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly issueRelayToken: (
    userId: string,
    raw: unknown,
    now?: Date,
  ) => Effect.Effect<unknown, IrohExpectedError>;
};

export class IrohTrustBroker extends Context.Tag("cmux/IrohTrustBroker")<
  IrohTrustBroker,
  IrohTrustBrokerShape
>() {}

export function makeIrohTrustBroker(
  repository: IrohRepositoryShape,
  relayMinter: IrohRelayMinterShape,
  config: IrohTrustBrokerConfigShape,
  relayPreferences: Pick<RelayRepositoryShape, "getPreference"> = {
    getPreference: () => Effect.succeed({
      preference: defaultRelayPreference,
      revision: 0,
    }),
  },
): IrohTrustBrokerShape {
  const accountRelayPreference = (
    userId: string,
  ): Effect.Effect<RelayPreference, IrohExpectedError> => relayPreferences
    .getPreference(userId)
    .pipe(
      Effect.map((record) => record.preference),
      Effect.mapError((cause) => new IrohDatabaseError({
        operation: "relayPreference.get",
        cause,
      })),
    );

  const issueRelayToken = (
    userId: string,
    raw: unknown,
    now = new Date(),
  ): Effect.Effect<unknown, IrohExpectedError> => Effect.gen(function* () {
    const { bindingId } = yield* parseEffect(() => parseBindingIdBody(raw));
    const reservation = yield* repository.reserveRelayIssuance({ userId, bindingId, now });
    const minted = yield* relayMinter.mint({
      endpointId: reservation.binding.endpointId,
      lifetimeSeconds: IROH_RELAY_TOKEN_LIFETIME_SECONDS,
      now,
    }).pipe(
      Effect.matchEffect({
        onFailure: (error) => repository.failRelayIssuance({
          userId,
          issuanceId: reservation.issuanceId,
          completedAt: new Date(),
          failureCode: error._tag === "IrohRelayMintError" ? error.code : "not_configured",
        }).pipe(
          Effect.catchAll(() => Effect.void),
          Effect.flatMap(() => Effect.fail(error)),
        ),
        onSuccess: Effect.succeed,
      }),
    );
    const completedAt = new Date();
    const completed = yield* repository.completeRelayIssuance({
      userId,
      issuanceId: reservation.issuanceId,
      bindingId: reservation.binding.id,
      endpointId: reservation.binding.endpointId,
      tokenHash: sha256(minted.token),
      completedAt,
      expiresAt: minted.expiresAt,
    });
    if (!completed) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    return {
      token: minted.token,
      expires_at: minted.expiresAt.toISOString(),
      refresh_after: new Date(now.getTime() + IROH_RELAY_TOKEN_REFRESH_SECONDS * 1_000).toISOString(),
      relay_fleet: MANAGED_RELAY_URLS,
    };
  });

  return {
    issueChallenge: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parseChallengeRequest(raw));
      const nonce = randomBytes(32).toString("base64url");
      const challenge = yield* repository.issueChallenge({
        userId,
        deviceUuid: request.deviceId,
        appInstanceId: request.appInstanceId,
        tag: request.tag,
        endpointId: request.endpointId,
        identityGeneration: request.identityGeneration,
        payloadSha256: request.payloadSha256,
        nonceHash: nonceHash(nonce),
        now,
        expiresAt: new Date(now.getTime() + IROH_CHALLENGE_LIFETIME_MS),
        challengeQuota: challengeQuotaForUser(config, userId),
      });
      return {
        challenge_id: challenge.id,
        nonce,
        expires_at: challenge.expiresAt.toISOString(),
      };
    }),

    register: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parseRegisterRequest(raw));
      const decoded = yield* parseEffect(() => decodeRegistrationPayload(request.payload, now));
      const challenge = yield* repository.findChallenge(userId, request.challengeId);
      if (!challenge) return yield* Effect.fail(new IrohNotFoundError({ resource: "challenge" }));
      if (challenge.consumedAt) return yield* Effect.fail(new IrohConflictError({ code: "challenge_replayed" }));
      if (challenge.expiresAt <= now) return yield* Effect.fail(new IrohForbiddenError({ code: "challenge_expired" }));
      if (!hashesEqual(challenge.payloadSha256, decoded.sha256)) {
        return yield* Effect.fail(new IrohForbiddenError({ code: "payload_hash_mismatch" }));
      }
      if (!hashesEqual(challenge.nonceHash, nonceHash(request.nonce))) {
        return yield* Effect.fail(new IrohForbiddenError({ code: "invalid_challenge_nonce" }));
      }
      yield* parseEffect(() => assertChallengeMatchesPayload(challenge, decoded.payload));
      yield* parseEffect(() => verifyEndpointRegistrationSignature({
        endpointId: decoded.payload.endpointId,
        challengeId: request.challengeId,
        nonce: request.nonce,
        payloadSha256: decoded.sha256,
        signature: request.signature,
      }));
      const relayPreference = yield* accountRelayPreference(userId);
      const savedCustomRelayURLs = customRelayURLs(relayPreference);
      const registration = yield* repository.consumeChallengeAndRegister({
        userId,
        challengeId: challenge.id,
        nonceHash: nonceHash(request.nonce),
        payload: {
          ...decoded.payload,
          pathHints: accountPrivateIrohPathHints(
            decoded.payload.pathHints,
            savedCustomRelayURLs,
          ),
        },
        now,
        bindingQuota: bindingQuotaForUser(config, userId),
      });

      // New registration is already committed before relay minting starts.
      // Refreshes keep their existing credential and use the dedicated relay
      // route when it expires, so path-hint churn cannot consume mint quotas.
      const relay = registration.created
        ? yield* issueRelayToken(userId, { bindingId: registration.binding.id }, now).pipe(
          Effect.map((value) => ({ status: "issued" as const, ...value as object })),
          Effect.catchAll(() => Effect.succeed({ status: "unavailable" as const })),
        )
        : { status: "not_requested" as const };
      return {
        binding: publicBinding(registration.binding, now, savedCustomRelayURLs),
        relay,
      };
    }),

    discover: (userId, now = new Date()) => Effect.gen(function* () {
      yield* repository.pruneExpiredState({ userId, now });
      const snapshot = yield* repository.discoverySnapshot({ userId, now });
      const relayPreference = yield* accountRelayPreference(userId);
      const savedCustomRelayURLs = customRelayURLs(relayPreference);
      const rendezvousKey = yield* parseEffect(() => deriveLanRendezvousKey(
        config.lanDiscoverySecretBase64,
        userId,
        snapshot.lanDiscoveryGeneration,
      ));
      const verificationKeys = yield* parseEffect(() => signingVerificationKeys(config));
      return {
        route_contract_version: 1,
        bindings: snapshot.bindings.map((binding) => publicBinding(
          binding,
          now,
          savedCustomRelayURLs,
        )),
        relay_fleet: MANAGED_RELAY_URLS,
        lan_rendezvous: {
          generation: snapshot.lanDiscoveryGeneration,
          key: rendezvousKey,
        },
        grant_verification_keys: verificationKeys.keySet,
      };
    }),

    revoke: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const { bindingId } = yield* parseEffect(() => parseBindingIdBody(raw));
      const revoked = yield* repository.revokeBinding({ userId, bindingId, now });
      if (!revoked) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      return { revoked: true, lan_rendezvous_rotated: true };
    }),

    issuePairGrant: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parsePairGrantRequest(raw));
      const bindings = yield* repository.findActiveBindings(userId, [
        request.initiatorBindingId,
        request.acceptorBindingId,
      ]);
      if (bindings.length !== 2) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      const byId = new Map(bindings.map((binding) => [binding.id, binding]));
      const initiator = byId.get(request.initiatorBindingId);
      const acceptor = byId.get(request.acceptorBindingId);
      if (!initiator || !acceptor) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      if (initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
        return yield* Effect.fail(new IrohForbiddenError({ code: "target_not_pairable" }));
      }
      if (initiator.deviceUuid === acceptor.deviceUuid) {
        return yield* Effect.fail(new IrohForbiddenError({ code: "pair_grant_same_device" }));
      }
      const issuedAtSeconds = Math.floor(now.getTime() / 1_000);
      const claims: PairGrantClaims = {
        jti: randomUUID(),
        iat: issuedAtSeconds,
        nbf: issuedAtSeconds - 5,
        exp: issuedAtSeconds + IROH_PAIR_GRANT_LIFETIME_SECONDS,
        alpn: IROH_ALPN,
        scope: IROH_PAIR_SCOPE,
        initiator: grantPeer(initiator),
        acceptor: grantPeer(acceptor),
      };
      const verificationKeys = yield* parseEffect(() => signingVerificationKeys(config));
      const signingKeyId = verificationKeys.keySet.current_kid;
      const token = yield* parseEffect(() => signPairGrant({
        privateKeyPem: config.grantSigningPrivateKeyPem,
        kid: signingKeyId,
        claims,
      }));
      yield* parseEffect(() => verifyPairGrant(token, verificationKeys.publicKeys, {
        initiator: claims.initiator,
        acceptor: claims.acceptor,
        nowSeconds: issuedAtSeconds,
      }));
      yield* repository.recordPairGrant({
        userId,
        jti: claims.jti,
        initiator: claims.initiator,
        acceptor: claims.acceptor,
        signingKeyId,
        alpn: IROH_ALPN,
        scope: IROH_PAIR_SCOPE,
        issuedAt: new Date(claims.iat * 1_000),
        notBefore: new Date(claims.nbf * 1_000),
        expiresAt: new Date(claims.exp * 1_000),
      });
      return { grant: token, expires_at: new Date(claims.exp * 1_000).toISOString() };
    }),

    issueEndpointAttestation: (userId, raw, now = new Date()) => Effect.gen(function* () {
      const { bindingId } = yield* parseEffect(() => parseBindingIdBody(raw));
      const bindings = yield* repository.findActiveBindings(userId, [bindingId]);
      const binding = bindings.length === 1 ? bindings[0] : undefined;
      if (!binding) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));

      const verificationKeys = yield* parseEffect(() => signingVerificationKeys(config));
      const issuedAtSeconds = Math.floor(now.getTime() / 1_000);
      const platform = yield* parseEffect(() => bindingPlatform(binding));
      const claims: EndpointAttestationClaims = {
        version: IROH_ENDPOINT_ATTESTATION_VERSION,
        jti: randomUUID(),
        sub: yield* parseEffect(() => deriveAccountSubject(config.accountSubjectSecretBase64, userId)),
        bindingId: binding.id,
        deviceId: binding.deviceUuid,
        endpointId: binding.endpointId,
        identityGeneration: binding.identityGeneration,
        platform,
        iat: issuedAtSeconds,
        nbf: issuedAtSeconds - 5,
        exp: issuedAtSeconds + IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS,
        alpn: IROH_ALPN,
        scope: IROH_ENDPOINT_ATTESTATION_SCOPE,
      };
      const attestation = yield* parseEffect(() => signEndpointAttestation({
        privateKeyPem: config.grantSigningPrivateKeyPem,
        kid: verificationKeys.keySet.current_kid,
        claims,
      }));
      yield* parseEffect(() => verifyEndpointAttestation(
        attestation,
        verificationKeys.publicKeys,
        {
          bindingId: binding.id,
          deviceId: binding.deviceUuid,
          endpointId: binding.endpointId,
          identityGeneration: binding.identityGeneration,
          platform,
          nowSeconds: issuedAtSeconds,
        },
      ));
      yield* repository.finalizeEndpointAttestation({
        userId,
        bindingId: binding.id,
        deviceId: binding.deviceUuid,
        endpointId: binding.endpointId,
        identityGeneration: binding.identityGeneration,
        platform,
      });
      return {
        attestation_version: IROH_ENDPOINT_ATTESTATION_VERSION,
        attestation,
        expires_at: new Date(claims.exp * 1_000).toISOString(),
        grant_verification_keys: verificationKeys.keySet,
      };
    }),

    issueRelayToken,
  };
}

export const IrohTrustBrokerLive = Layer.effect(
  IrohTrustBroker,
  Effect.gen(function* () {
    return makeIrohTrustBroker(
      yield* IrohRepository,
      yield* IrohRelayMinter,
      yield* IrohTrustBrokerConfig,
      yield* RelayRepository,
    );
  }),
);

const IrohRelayMinterWithConfig = IrohRelayMinterLive.pipe(
  Layer.provide(IrohTrustBrokerConfigLive),
);

export const IrohTrustBrokerRuntime = IrohTrustBrokerLive.pipe(
  Layer.provide(Layer.mergeAll(
    IrohRepositoryLive,
    RelayRepositoryLive,
    IrohTrustBrokerConfigLive,
    IrohRelayMinterWithConfig,
  )),
);

function parseEffect<A>(run: () => A): Effect.Effect<A, IrohExpectedError> {
  return Effect.try({
    try: run,
    catch: (error) => {
      const tag = (error as { _tag?: unknown } | null)?._tag;
      if (typeof tag === "string" && tag.startsWith("Iroh")) return error as IrohExpectedError;
      return new IrohInvalidInputError({ code: "invalid_input" });
    },
  });
}

function publicBinding(
  binding: IrohBindingRecord,
  now: Date,
  savedCustomRelayURLs: ReadonlySet<string>,
): object {
  return {
    binding_id: binding.id,
    device_id: binding.deviceUuid,
    app_instance_id: binding.appInstanceId,
    tag: binding.tag,
    platform: binding.platform,
    display_name: binding.displayName,
    endpoint_id: binding.endpointId,
    identity_generation: binding.identityGeneration,
    pairing_enabled: binding.pairingEnabled,
    capabilities: binding.capabilities,
    ...(binding.directPortV4 === null && binding.directPortV6 === null
      ? {}
      : {
          direct_ports: {
            ...(binding.directPortV4 === null ? {} : { ipv4: binding.directPortV4 }),
            ...(binding.directPortV6 === null ? {} : { ipv6: binding.directPortV6 }),
          },
        }),
    path_hints: accountPrivateIrohPathHints(binding.pathHints.flatMap((hint): IrohPathHint[] => {
      try {
        return [parseIrohPathHint(hint, now)];
      } catch {
        return [];
      }
    }), savedCustomRelayURLs),
    last_seen_at: binding.lastSeenAt.toISOString(),
  };
}

function customRelayURLs(preference: RelayPreference): ReadonlySet<string> {
  return new Set(preference.customRelays.map((relay) => relay.url));
}

function grantPeer(binding: IrohBindingRecord): PairGrantPeer {
  return {
    bindingId: binding.id,
    deviceId: binding.deviceUuid,
    tag: binding.tag,
    platform: bindingPlatform(binding),
    endpointId: binding.endpointId,
    identityGeneration: binding.identityGeneration,
  };
}

function signingVerificationKeys(config: IrohTrustBrokerConfigShape) {
  const verificationKeys = parseVerificationKeys(config.grantVerificationKeysJson);
  assertCurrentSigningKey({
    privateKeyPem: config.grantSigningPrivateKeyPem,
    kid: config.grantSigningKid,
    verificationKeys,
  });
  return verificationKeys;
}

function bindingPlatform(binding: IrohBindingRecord): "mac" | "ios" {
  if (binding.platform !== "mac" && binding.platform !== "ios") {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  return binding.platform;
}

// Stack bearer authentication alone is never sufficient to mutate path hints.
// Until the dedicated endpoint-signed monotonic update route lands, clients
// refresh watch_addr output only through a new signed registration challenge.
export const IROH_SIGNED_PATH_HINT_UPDATE_FOLLOWUP = "endpoint-signed-monotonic-watch-addr-update-v1";
