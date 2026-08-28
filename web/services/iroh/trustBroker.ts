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
  verifyBindingRequestSignature,
  verifyEndpointAttestation,
  verifyEndpointRegistrationSignature,
  verifyPairGrant,
  verifySelfProofRegistrationSignature,
  type EndpointAttestationClaims,
  type IrohBindingRequestProof,
  type PairGrantClaims,
  type PairGrantPeer,
} from "./crypto";
import {
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
  IROH_SELF_PROOF_MAX_SKEW_MS,
  IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS,
  IROH_ENDPOINT_ATTESTATION_SCOPE,
  IROH_ENDPOINT_ATTESTATION_VERSION,
  IROH_PAIR_GRANT_LIFETIME_SECONDS,
  IROH_PAIR_SCOPE,
  assertChallengeMatchesPayload,
  decodeRegistrationPayload,
  parseBindingIdBody,
  parsePublishEndpointRecordBody,
  parseRevokeBindingBody,
  parseChallengeRequest,
  parseIrohPathHint,
  parsePairGrantRequest,
  parseRegisterRequest,
  type IrohPathHint,
} from "./model";
import { canIOSBindingUseMac } from "./buildCompatibility";
import {
  IrohRepository,
  IrohRepositoryLive,
  type IrohBindingRecord,
  type IrohRegistrationCommit,
  type IrohRepositoryShape,
} from "./repository";
import {
  encodeIrohDiscoveryCursor,
  legacyIrohDiscoveryRequest,
  parseIrohDiscoveryRequest,
} from "./discoveryPagination";
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
  isPublishableAttachedRelayURL,
} from "./publicationPolicy";
import {
  discoveryScopeMatchesRegistration,
  irohDiscoveryScopeJSON,
  type IrohDiscoveryScope,
} from "./discoveryScope";

export type IrohTrustBrokerShape = {
  readonly issueChallenge: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly register: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly discover: (
    userId: string,
    now?: Date,
    request?: unknown,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly discoverComplete: (
    userId: string,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly discoverScoped: (
    userId: string,
    scope: IrohDiscoveryScope,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly revoke: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly publishEndpointRecord: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly issuePairGrant: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
  readonly issueEndpointAttestation: (
    userId: string,
    raw: unknown,
    now?: Date,
    clientNamespace?: string,
    bindingProof?: IrohBindingRequestProof,
  ) => Effect.Effect<unknown, IrohExpectedError>;
};

export class IrohTrustBroker extends Context.Tag("cmux/IrohTrustBroker")<
  IrohTrustBroker,
  IrohTrustBrokerShape
>() {}

export function makeIrohTrustBroker(
  repository: IrohRepositoryShape,
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

  const authorizeBinding = (
    userId: string,
    proof: IrohBindingRequestProof | undefined,
    clientNamespace: string,
    now: Date,
    allowRevokedSelf = false,
  ): Effect.Effect<IrohBindingRecord | undefined, IrohExpectedError> => Effect.gen(function* () {
    if (!proof) {
      if (clientNamespace === "legacy") return undefined;
      return yield* Effect.fail(
        new IrohForbiddenError({ code: "binding_request_proof_required" }),
      );
    }
    const binding = allowRevokedSelf
      ? yield* repository.findBindingForRevocationProof(userId, proof.bindingId)
      : (yield* repository.findActiveBindings(userId, [proof.bindingId]))[0];
    if (!binding) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    if (binding.clientNamespace !== clientNamespace) {
      return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    }
    yield* parseEffect(() => verifyBindingRequestSignature({
      ...proof,
      endpointId: binding.endpointId,
      nowSeconds: Math.floor(now.getTime() / 1_000),
    }));
    return binding;
  });

  const discover = (
    userId: string,
    now = new Date(),
    rawRequest?: unknown,
    clientNamespace = "legacy",
    bindingProof?: IrohBindingRequestProof,
    knownCustomRelayURLs?: ReadonlySet<string>,
    trustedCaller?: IrohBindingRecord,
  ): Effect.Effect<unknown, IrohExpectedError> => Effect.gen(function* () {
    const request = rawRequest === undefined
      ? legacyIrohDiscoveryRequest()
      : yield* parseEffect(() => parseIrohDiscoveryRequest(rawRequest));
    const caller = trustedCaller
      ?? (yield* authorizeBinding(userId, bindingProof, clientNamespace, now));
    yield* repository.pruneExpiredState({ userId, now });
    const snapshot = yield* repository.discoveryPage({
      userId,
      clientNamespace,
      callerBindingId: caller?.id,
      callerPlatform: caller
        ? yield* parseEffect(() => bindingPlatform(caller))
        : undefined,
      now,
      pageSize: request.pageSize,
      ...(request.cursor ? { cursor: request.cursor } : {}),
    });
    const response = yield* serializeDiscovery(
      userId,
      now,
      snapshot,
      knownCustomRelayURLs,
    );
    return request.paginated
      ? {
        ...response,
        next_cursor: snapshot.nextCursor
          ? encodeIrohDiscoveryCursor(snapshot.nextCursor)
          : null,
      }
      : response;
  });

  const discoverComplete = (
    userId: string,
    now = new Date(),
    clientNamespace = "legacy",
    bindingProof?: IrohBindingRequestProof,
  ): Effect.Effect<unknown, IrohExpectedError> => Effect.gen(function* () {
    const caller = yield* authorizeBinding(userId, bindingProof, clientNamespace, now);
    yield* repository.pruneExpiredState({ userId, now });
    const snapshot = yield* repository.discoverySnapshot({
      userId,
      clientNamespace,
      callerBindingId: caller?.id,
      callerPlatform: caller
        ? yield* parseEffect(() => bindingPlatform(caller))
        : undefined,
      now,
    });
    return yield* serializeDiscovery(userId, now, snapshot);
  });

  const discoverScoped = (
    userId: string,
    scope: IrohDiscoveryScope,
    now = new Date(),
    clientNamespace = "legacy",
    bindingProof?: IrohBindingRequestProof,
    knownCustomRelayURLs?: ReadonlySet<string>,
    trustedCaller?: IrohBindingRecord,
  ): Effect.Effect<unknown, IrohExpectedError> => Effect.gen(function* () {
    const caller = trustedCaller
      ?? (yield* authorizeBinding(userId, bindingProof, clientNamespace, now));
    yield* repository.pruneExpiredState({ userId, now });
    const snapshot = yield* repository.discoverySnapshot({
      userId,
      clientNamespace,
      callerBindingId: caller?.id,
      callerPlatform: caller
        ? yield* parseEffect(() => bindingPlatform(caller))
        : undefined,
      now,
      scope,
    });
    return yield* serializeDiscovery(
      userId,
      now,
      snapshot,
      knownCustomRelayURLs,
    );
  });

  const serializeDiscovery = (
    userId: string,
    now: Date,
    snapshot: {
      readonly bindings: readonly IrohBindingRecord[];
      readonly lanDiscoveryGeneration: number;
      readonly accountRevision: number;
    },
    knownCustomRelayURLs?: ReadonlySet<string>,
  ): Effect.Effect<Record<string, unknown>, IrohExpectedError> => Effect.gen(function* () {
    const savedCustomRelayURLs = knownCustomRelayURLs
      ?? customRelayURLs(yield* accountRelayPreference(userId));
    const rendezvousKey = yield* parseEffect(() => deriveLanRendezvousKey(
      config.lanDiscoverySecretBase64,
      userId,
      snapshot.lanDiscoveryGeneration,
    ));
    const verificationKeys = yield* parseEffect(() => signingVerificationKeys(config));
    return {
      route_contract_version: 1 as const,
      revision: snapshot.accountRevision,
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
  });

  return {
    issueChallenge: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
    ) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parseChallengeRequest(raw));
      if (request.clientNamespace !== clientNamespace) {
        return yield* Effect.fail(
          new IrohForbiddenError({ code: "client_namespace_mismatch" }),
        );
      }
      const nonce = randomBytes(32).toString("base64url");
      const challenge = yield* repository.issueChallenge({
        userId,
        deviceUuid: request.deviceId,
        appInstanceId: request.appInstanceId,
        clientNamespace: request.clientNamespace,
        tag: request.tag,
        endpointId: request.endpointId,
        identityGeneration: request.identityGeneration,
        payloadSha256: request.payloadSha256,
        nonceHash: nonceHash(nonce),
        now,
        expiresAt: new Date(now.getTime() + IROH_CHALLENGE_LIFETIME_MS),
      });
      return {
        challenge_id: challenge.id,
        nonce,
        expires_at: challenge.expiresAt.toISOString(),
      };
    }),

    register: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
    ) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parseRegisterRequest(raw));
      const decoded = yield* parseEffect(() => decodeRegistrationPayload(request.payload, now));
      if (decoded.payload.clientNamespace !== clientNamespace) {
        return yield* Effect.fail(
          new IrohForbiddenError({ code: "client_namespace_mismatch" }),
        );
      }
      if (
        request.discoveryScope
        && !discoveryScopeMatchesRegistration(
          request.discoveryScope,
          decoded.payload,
        )
      ) {
        return yield* Effect.fail(new IrohInvalidInputError({
          code: "invalid_discovery_scope",
        }));
      }
      const relayPreference = yield* accountRelayPreference(userId);
      const savedCustomRelayURLs = customRelayURLs(relayPreference);
      const registrationPayload = {
        ...decoded.payload,
        pathHints: accountPrivateIrohPathHints(
          decoded.payload.pathHints,
          savedCustomRelayURLs,
        ),
      };
      let registration: IrohRegistrationCommit;
      if (request.challengeId !== undefined) {
        const challengeId = request.challengeId;
        const challenge = yield* repository.findChallenge(userId, challengeId);
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
          challengeId,
          nonce: request.nonce,
          payloadSha256: decoded.sha256,
          signature: request.signature,
        }));
        registration = yield* repository.consumeChallengeAndRegister({
          userId,
          challengeId: challenge.id,
          nonceHash: nonceHash(request.nonce),
          payload: registrationPayload,
          now,
        });
      } else {
        // One-round self-contained proof: freshness comes from the signed
        // timestamp (the same ±5-minute window binding-request proofs get),
        // one-use comes from the atomic nonce dedupe inside
        // registerWithSelfProof.
        const issuedAtSeconds = request.issuedAtSeconds;
        if (issuedAtSeconds === undefined) {
          return yield* Effect.fail(new IrohInvalidInputError({
            code: "invalid_issued_at",
          }));
        }
        if (
          Math.abs(now.getTime() - issuedAtSeconds * 1_000)
            > IROH_SELF_PROOF_MAX_SKEW_MS
        ) {
          return yield* Effect.fail(
            new IrohForbiddenError({ code: "self_proof_expired" }),
          );
        }
        yield* parseEffect(() => verifySelfProofRegistrationSignature({
          endpointId: decoded.payload.endpointId,
          issuedAtSeconds,
          nonce: request.nonce,
          payloadSha256: decoded.sha256,
          signature: request.signature,
        }));
        registration = yield* repository.registerWithSelfProof({
          userId,
          nonceHash: nonceHash(request.nonce),
          payloadSha256: decoded.sha256,
          payload: registrationPayload,
          now,
          // The consumed dedupe row must outlive the proof's entire
          // acceptance window (a future-dated issuedAt stays valid until
          // issuedAt + skew), plus a boundary second.
          dedupeExpiresAt: new Date(
            issuedAtSeconds * 1_000 + IROH_SELF_PROOF_MAX_SKEW_MS + 1_000,
          ),
        });
      }

      // Registration never mints a relay credential: relay admission is the
      // relay's allow hook against the proven endpoint key, so no client
      // credential exists at all. "unavailable" preserves the response shape
      // the pre-registry bootstrap produced when the removed n0-hosted minter
      // was unconfigured, which production always was.
      const relay = registration.created
        ? { status: "unavailable" as const }
        : { status: "not_requested" as const };
      const discovery = request.discoveryScope
        ? (yield* discoverScoped(
          userId,
          request.discoveryScope,
          now,
          decoded.payload.clientNamespace,
          undefined,
          savedCustomRelayURLs,
          registration.binding,
        )) as Record<string, unknown>
        : (yield* discover(
          userId,
          now,
          { pageSize: "128" },
          decoded.payload.clientNamespace,
          undefined,
          savedCustomRelayURLs,
          registration.binding,
        )) as Record<string, unknown>;
      return {
        revision: registration.accountRevision,
        binding: publicBinding(registration.binding, now, savedCustomRelayURLs),
        relay,
        discovery,
        discovery_complete: request.discoveryScope
          ? false
          : discovery.next_cursor === null,
        ...(request.discoveryScope
          ? {
            discovery_scope: irohDiscoveryScopeJSON(request.discoveryScope),
            discovery_scope_complete: true as const,
          }
          : {}),
      };
    }),

    discover,
    discoverComplete,
    discoverScoped,

    revoke: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
      bindingProof,
    ) => Effect.gen(function* () {
      const { bindingId, intent } = yield* parseEffect(
        () => parseRevokeBindingBody(raw),
      );
      const caller = yield* authorizeBinding(
        userId,
        bindingProof,
        clientNamespace,
        now,
        true,
      );
      const result = yield* repository.revokeBinding({
        userId,
        bindingId,
        clientNamespace: caller?.clientNamespace ?? clientNamespace,
        authorizedBindingId: caller?.id,
        intent,
        now,
      });
      if (!result.revoked) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      return {
        revoked: true,
        revision: result.accountRevision,
        lan_rendezvous_rotated: true,
      };
    }),

    // Stores the caller's own signed pkarr record on its binding. Write
    // admission only: the binding-request proof authenticates the caller,
    // and the record's embedded public key must equal the caller's endpoint
    // id. The ed25519 record signature is verified by every reader, so this
    // storage stays untrusted (any cache or replica may serve it).
    publishEndpointRecord: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
      bindingProof,
    ) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parsePublishEndpointRecordBody(raw));
      const caller = yield* authorizeBinding(userId, bindingProof, clientNamespace, now);
      // Unlike legacy read paths, record publication always requires the
      // binding-request proof: an account credential alone must not be able
      // to overwrite another device's published addresses.
      if (!caller || caller.id !== request.bindingId) {
        return yield* Effect.fail(
          new IrohForbiddenError({ code: "binding_request_proof_required" }),
        );
      }
      if (caller.endpointId !== request.recordEndpointId) {
        return yield* Effect.fail(
          new IrohForbiddenError({ code: "endpoint_record_key_mismatch" }),
        );
      }
      const result = yield* repository.publishEndpointRecord({
        userId,
        bindingId: request.bindingId,
        endpointId: request.recordEndpointId,
        record: request.record,
        now,
      });
      if (!result.published) {
        return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      }
      return { published: true };
    }),

    issuePairGrant: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
      bindingProof,
    ) => Effect.gen(function* () {
      const request = yield* parseEffect(() => parsePairGrantRequest(raw));
      const caller = yield* authorizeBinding(userId, bindingProof, clientNamespace, now);
      if (caller && caller.id !== request.initiatorBindingId) {
        return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      }
      const bindings = yield* repository.findActiveBindings(userId, [
        request.initiatorBindingId,
        request.acceptorBindingId,
      ]);
      if (bindings.length !== 2) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      const byId = new Map(bindings.map((binding) => [binding.id, binding]));
      const initiator = byId.get(request.initiatorBindingId);
      const acceptor = byId.get(request.acceptorBindingId);
      if (!initiator || !acceptor) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      if (!caller && initiator.clientNamespace !== "legacy") {
        return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      }
      if (initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
        return yield* Effect.fail(new IrohForbiddenError({ code: "target_not_pairable" }));
      }
      if (!canIOSBindingUseMac(initiator, acceptor)) {
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

    issueEndpointAttestation: (
      userId,
      raw,
      now = new Date(),
      clientNamespace = "legacy",
      bindingProof,
    ) => Effect.gen(function* () {
      const { bindingId } = yield* parseEffect(() => parseBindingIdBody(raw));
      const caller = yield* authorizeBinding(userId, bindingProof, clientNamespace, now);
      if (caller && caller.id !== bindingId) {
        return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      }
      const bindings = yield* repository.findActiveBindings(userId, [bindingId]);
      const binding = bindings.length === 1 ? bindings[0] : undefined;
      if (!binding) return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      if (!caller && binding.clientNamespace !== "legacy") {
        return yield* Effect.fail(new IrohNotFoundError({ resource: "binding" }));
      }

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
  };
}

export const IrohTrustBrokerLive = Layer.effect(
  IrohTrustBroker,
  Effect.gen(function* () {
    return makeIrohTrustBroker(
      yield* IrohRepository,
      yield* IrohTrustBrokerConfig,
      yield* RelayRepository,
    );
  }),
);

export const IrohTrustBrokerRuntime = IrohTrustBrokerLive.pipe(
  Layer.provide(Layer.mergeAll(
    IrohRepositoryLive,
    RelayRepositoryLive,
    IrohTrustBrokerConfigLive,
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
    client_namespace: binding.clientNamespace,
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
    path_hints: bindingPathHints(binding, now, savedCustomRelayURLs),
    last_seen_at: binding.lastSeenAt.toISOString(),
    // Opaque signed pkarr record; readers verify its ed25519 signature
    // themselves, so publication needs no server-side laundering beyond the
    // write-admission checks in publishEndpointRecord.
    ...(binding.endpointRecord === null
      ? {}
      : { endpoint_record: binding.endpointRecord }),
  };
}

/**
 * Serves the relay-reported attach route ahead of endpoint-published hints.
 *
 * The fleet reports attach/detach per admitted connection (cmux-relay
 * attach reporting), so `relayAttachedUrl` is live server-side truth and the
 * phone learns "reachable via relay Y" without the Mac's client-side
 * post-attach republish. The synthesized hint reuses the standard path-hint
 * shape so existing clients dial it unchanged; the client-published hint for
 * the same URL is dropped as redundant, and every other client hint stays a
 * fallback while pre-attach-reporting fleet relays remain deployed.
 */
function bindingPathHints(
  binding: IrohBindingRecord,
  now: Date,
  savedCustomRelayURLs: ReadonlySet<string>,
): IrohPathHint[] {
  const clientHints = accountPrivateIrohPathHints(
    binding.pathHints.flatMap((hint): IrohPathHint[] => {
      try {
        return [parseIrohPathHint(hint, now)];
      } catch {
        return [];
      }
    }),
    savedCustomRelayURLs,
  );
  const attachedURL = binding.relayAttachedUrl;
  if (
    attachedURL === null ||
    !isPublishableAttachedRelayURL(attachedURL, savedCustomRelayURLs) ||
    !attachmentCorroborated(binding, now)
  ) {
    return clientHints;
  }
  const serverHint: IrohPathHint = {
    kind: "relay_url",
    value: attachedURL,
    source: "native",
    privacy_scope: "public_internet",
    // Attachment is current as of this read; clients bound hint freshness to
    // observed_at + 1h, and every discovery read re-serves the live state.
    observed_at: now.toISOString(),
    expires_at: new Date(now.getTime() + SERVER_RELAY_HINT_TTL_MS).toISOString(),
  };
  return [
    serverHint,
    ...clientHints.filter((hint) =>
      !(hint.kind === "relay_url" && hint.value === attachedURL)),
  ];
}

/** Half the model's 1h hint-lifetime cap; refreshed by every discovery read. */
const SERVER_RELAY_HINT_TTL_MS = 30 * 60 * 1_000;

/**
 * Detach reports are fire-and-forget, so a relay that dies together with its
 * report leaves `relayAttachedUrl` behind; without a liveness bound that dead
 * route would be re-served as fresh forever. An attachment is served only
 * while some live evidence is younger than this window: the attach report
 * itself, or the binding's `lastSeenAt` (a live Mac re-registers at least
 * hourly to keep its ≤1h path hints and binding freshness lease current,
 * and a Mac that outlives its relay reattaches elsewhere, which overwrites
 * the URL). A Mac that goes dark with its relay stops refreshing both, so
 * the stale route ages out within this window.
 */
const SERVER_RELAY_ATTACH_LIVENESS_MS = 60 * 60 * 1_000;

function attachmentCorroborated(binding: IrohBindingRecord, now: Date): boolean {
  const freshestEvidence = Math.max(
    binding.relayAttachReportedAt?.getTime() ?? 0,
    binding.lastSeenAt.getTime(),
  );
  return now.getTime() - freshestEvidence <= SERVER_RELAY_ATTACH_LIVENESS_MS;
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
