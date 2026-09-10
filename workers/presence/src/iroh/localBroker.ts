import { randomBytes, randomUUID } from "node:crypto";
import { and, desc, eq, inArray, isNull } from "drizzle-orm";
import { Effect } from "effect";
import { accountBindings, accountChallenges, accountDrizzleSchema } from "../accountDrizzleSchema";
import { accountDrizzleDatabase, type AccountDrizzleDatabase } from "../accountDrizzleDatabase";
import {
  deriveLanRendezvousKey,
  deriveAccountSubject,
  nonceHash,
  signEndpointAttestation,
  signPairGrant,
  verifyBindingRequestSignature,
  verifyEndpointRegistrationSignature,
  type IrohBindingRequestProof,
} from "./crypto";
import {
  decodeRegistrationPayload,
  parseBindingIdBody,
  parseChallengeRequest,
  parsePairGrantRequest,
  parseRegisterRequest,
  parseRevokeBindingBody,
  assertChallengeMatchesPayload,
  type IrohRegistrationPayload,
} from "./model";
import { IrohConflictError, IrohForbiddenError, IrohInvalidInputError, IrohNotFoundError } from "./errors";
import { MANAGED_RELAY_URLS } from "./publicationPolicy";
import { IROH_CHALLENGE_LIFETIME_MS } from "./model";

export type LocalIrohConfig = {
  readonly lanDiscoverySecretBase64: string;
  readonly accountSubjectSecretBase64?: string;
  readonly grantVerificationKeys: unknown;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
};

type StoredBinding = {
  readonly id: string;
  readonly userId: string;
  readonly deviceUuid: string;
  readonly appInstanceId: string;
  readonly clientNamespace: string;
  readonly tag: string;
  readonly platform: "mac" | "ios";
  readonly displayName?: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly pairingEnabled: boolean;
  readonly capabilities: readonly string[];
  readonly pathHints: readonly unknown[];
  readonly registeredAt: number;
  readonly updatedAt: number;
  readonly revokedAt: number | null;
};

type StoredChallenge = {
  readonly userId: string;
  readonly deviceUuid: string;
  readonly appInstanceId: string;
  readonly clientNamespace: string;
  readonly tag: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly payloadSha256: string;
  readonly nonceHash: string;
};

export class LocalIrohBroker {
  private readonly db: AccountDrizzleDatabase;
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly config: LocalIrohConfig,
  ) {
    this.db = accountDrizzleDatabase(storage);
  }

  issueChallenge(userId: string, raw: unknown, now = Date.now(), namespace = "legacy") {
    return Effect.try({
      try: () => {
        const request = parseChallengeRequest(raw);
        if (request.clientNamespace !== namespace) throw new IrohForbiddenError({ code: "client_namespace_mismatch" });
        const challengeId = randomUUID();
        const nonce = randomBytes(32).toString("base64url");
        const payload: StoredChallenge = {
          userId,
          deviceUuid: request.deviceId,
          appInstanceId: request.appInstanceId,
          clientNamespace: request.clientNamespace,
          tag: request.tag,
          endpointId: request.endpointId,
          identityGeneration: request.identityGeneration,
          payloadSha256: request.payloadSha256,
          nonceHash: nonceHash(nonce),
        };
        const encoded = JSON.stringify(payload);
        this.db.insert(accountChallenges).values({
          challengeId,
          payload: encoded,
          payloadBytes: new TextEncoder().encode(encoded).byteLength,
          expiresAt: now + IROH_CHALLENGE_LIFETIME_MS,
        }).run();
        return { challenge_id: challengeId, nonce, expires_at: new Date(now + IROH_CHALLENGE_LIFETIME_MS).toISOString() };
      },
      catch: (error) => error,
    });
  }

  register(userId: string, raw: unknown, now = Date.now(), namespace = "legacy") {
    return Effect.try({
      try: () => {
        const request = parseRegisterRequest(raw);
        const decoded = decodeRegistrationPayload(request.payload, new Date(now));
        const challengeRow = this.db.select().from(accountChallenges)
          .where(eq(accountChallenges.challengeId, request.challengeId)).get();
        if (!challengeRow) throw new IrohNotFoundError({ resource: "challenge" });
        const challenge = JSON.parse(challengeRow.payload) as StoredChallenge;
        if (challenge.userId !== userId || challenge.clientNamespace !== namespace) throw new IrohNotFoundError({ resource: "challenge" });
        if (challengeRow.expiresAt <= now) throw new IrohForbiddenError({ code: "challenge_expired" });
        if (challenge.payloadSha256 !== decoded.sha256) throw new IrohForbiddenError({ code: "payload_hash_mismatch" });
        if (challenge.nonceHash !== nonceHash(request.nonce)) throw new IrohForbiddenError({ code: "invalid_challenge_nonce" });
        assertChallengeMatchesPayload(challenge as never, decoded.payload);
        verifyEndpointRegistrationSignature({
          endpointId: decoded.payload.endpointId,
          challengeId: request.challengeId,
          nonce: request.nonce,
          payloadSha256: decoded.sha256,
          signature: request.signature,
        });
        const bindingId = randomUUID();
        const payload = JSON.stringify(decoded.payload);
        const payloadBytes = new TextEncoder().encode(payload).byteLength;
        const existing = this.db.select().from(accountBindings).where(and(
          eq(accountBindings.deviceId, decoded.payload.deviceId),
          eq(accountBindings.clientNamespace, decoded.payload.clientNamespace),
          eq(accountBindings.endpointId, decoded.payload.endpointId),
          isNull(accountBindings.revokedAt),
        )).get();
        const finalId = existing?.bindingId ?? bindingId;
        if (existing) {
          this.db.update(accountBindings).set({ payload, payloadBytes, lastSeenAt: now }).where(eq(accountBindings.bindingId, finalId)).run();
        } else {
          this.db.insert(accountBindings).values({
            bindingId: finalId, endpointId: decoded.payload.endpointId, deviceId: decoded.payload.deviceId,
            clientNamespace: decoded.payload.clientNamespace, platform: decoded.payload.platform, payload,
            payloadBytes, lastSeenAt: now, registeredAt: now, revokedAt: null, tombstoneExpiresAt: null,
          }).run();
        }
        this.db.delete(accountChallenges).where(eq(accountChallenges.challengeId, request.challengeId)).run();
        const binding = this.readBinding(finalId, userId);
        return { revision: now, binding: this.publicBinding(binding), relay: { status: "not_requested" as const }, discovery: this.discovery(userId, namespace, now), discovery_complete: true };
      },
      catch: (error) => error,
    });
  }

  discover(userId: string, namespace = "legacy", now = Date.now()) {
    return Effect.try({
      try: () => this.discovery(userId, namespace, now),
      catch: (error) => error,
    });
  }

  revoke(userId: string, raw: unknown, now = Date.now(), namespace = "legacy", proof?: IrohBindingRequestProof) {
    return Effect.try({
      try: () => {
        const { bindingId } = parseRevokeBindingBody(raw);
        const binding = this.readBinding(bindingId, userId);
        if (!binding || binding.clientNamespace !== namespace) throw new IrohNotFoundError({ resource: "binding" });
        if (proof) verifyBindingRequestSignature({ ...proof, endpointId: binding.endpointId, nowSeconds: Math.floor(now / 1000) });
        this.db.update(accountBindings).set({ revokedAt: now, tombstoneExpiresAt: now + 30 * 24 * 60 * 60 * 1000 }).where(eq(accountBindings.bindingId, bindingId)).run();
        return { revoked: true, revision: now, lan_rendezvous_rotated: true };
      },
      catch: (error) => error,
    });
  }

  issuePairGrant(userId: string, raw: unknown, now = Date.now(), namespace = "legacy", proof?: IrohBindingRequestProof) {
    return Effect.try({
      try: () => {
        const request = parsePairGrantRequest(raw);
        const initiator = this.readBinding(request.initiatorBindingId, userId);
        const acceptor = this.readBinding(request.acceptorBindingId, userId);
        if (initiator.clientNamespace !== namespace || initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
          throw new IrohForbiddenError({ code: "target_not_pairable" });
        }
        if (proof) verifyBindingRequestSignature({ ...proof, endpointId: initiator.endpointId, nowSeconds: Math.floor(now / 1000) });
        if (!this.config.grantSigningPrivateKeyPem || !this.config.grantSigningKid) throw new IrohForbiddenError({ code: "grant_signing_not_configured" });
        const issued = Math.floor(now / 1000);
        const claims = {
          jti: randomUUID(), iat: issued, nbf: issued - 5, exp: issued + 7 * 24 * 60 * 60,
          alpn: "cmux/mobile/1" as const, scope: "cmux.mobile.attach" as const,
          initiator: { bindingId: initiator.id, deviceId: initiator.deviceUuid, tag: initiator.tag, platform: initiator.platform, endpointId: initiator.endpointId, identityGeneration: initiator.identityGeneration },
          acceptor: { bindingId: acceptor.id, deviceId: acceptor.deviceUuid, tag: acceptor.tag, platform: acceptor.platform, endpointId: acceptor.endpointId, identityGeneration: acceptor.identityGeneration },
        };
        const token = signPairGrant({ privateKeyPem: this.config.grantSigningPrivateKeyPem, kid: this.config.grantSigningKid, claims });
        return { grant: token, expires_at: new Date(claims.exp * 1000).toISOString() };
      },
      catch: (error) => error,
    });
  }

  issueEndpointAttestation(userId: string, raw: unknown, now = Date.now(), namespace = "legacy", proof?: IrohBindingRequestProof) {
    return Effect.try({
      try: () => {
        const { bindingId } = parseBindingIdBody(raw);
        const binding = this.readBinding(bindingId, userId);
        if (binding.clientNamespace !== namespace) throw new IrohNotFoundError({ resource: "binding" });
        if (proof) verifyBindingRequestSignature({ ...proof, endpointId: binding.endpointId, nowSeconds: Math.floor(now / 1000) });
        if (!this.config.grantSigningPrivateKeyPem || !this.config.grantSigningKid || !this.config.accountSubjectSecretBase64) {
          throw new IrohForbiddenError({ code: "attestation_signing_not_configured" });
        }
        const issued = Math.floor(now / 1000);
        const claims = {
          version: 1 as const, jti: randomUUID(), sub: deriveAccountSubject(this.config.accountSubjectSecretBase64, userId),
          bindingId: binding.id, deviceId: binding.deviceUuid, endpointId: binding.endpointId,
          identityGeneration: binding.identityGeneration, platform: binding.platform,
          iat: issued, nbf: issued - 5, exp: issued + 24 * 60 * 60,
          alpn: "cmux/mobile/1" as const, scope: "cmux.offline-pair.same-account" as const,
        };
        const attestation = signEndpointAttestation({ privateKeyPem: this.config.grantSigningPrivateKeyPem, kid: this.config.grantSigningKid, claims });
        return { attestation_version: 1, attestation, expires_at: new Date(claims.exp * 1000).toISOString(), grant_verification_keys: this.config.grantVerificationKeys };
      },
      catch: (error) => error,
    });
  }

  private discovery(userId: string, namespace: string, now: number) {
    const rows = this.db.select().from(accountBindings).where(and(eq(accountBindings.clientNamespace, namespace), isNull(accountBindings.revokedAt))).all();
    const bindings = rows.map((row) => this.publicBinding(this.readBinding(row.bindingId, userId), now));
    const generation = 1;
    const rendezvous = deriveLanRendezvousKey(this.config.lanDiscoverySecretBase64, userId, generation);
    return { route_contract_version: 1, revision: now, bindings, relay_fleet: MANAGED_RELAY_URLS, lan_rendezvous: { generation, key: rendezvous }, grant_verification_keys: this.config.grantVerificationKeys };
  }

  private readBinding(bindingId: string, userId: string): StoredBinding {
    const row = this.db.select().from(accountBindings).where(eq(accountBindings.bindingId, bindingId)).get();
    if (!row) throw new IrohNotFoundError({ resource: "binding" });
    const payload = JSON.parse(row.payload) as IrohRegistrationPayload;
    if (payload.deviceId === undefined) throw new IrohInvalidInputError({ code: "invalid_binding_payload" });
    return {
      id: row.bindingId, userId, deviceUuid: payload.deviceId, appInstanceId: payload.appInstanceId,
      clientNamespace: row.clientNamespace, tag: payload.tag, platform: payload.platform,
      ...(payload.displayName === undefined ? {} : { displayName: payload.displayName }), endpointId: row.endpointId,
      identityGeneration: payload.identityGeneration, pairingEnabled: payload.pairingEnabled,
      capabilities: payload.capabilities, pathHints: payload.pathHints, registeredAt: row.registeredAt,
      updatedAt: row.lastSeenAt, revokedAt: row.revokedAt,
    };
  }

  private publicBinding(binding: StoredBinding, now = Date.now()) {
    return {
      binding_id: binding.id, device_id: binding.deviceUuid, app_instance_id: binding.appInstanceId,
      client_namespace: binding.clientNamespace, tag: binding.tag, platform: binding.platform,
      display_name: binding.displayName, endpoint_id: binding.endpointId,
      identity_generation: binding.identityGeneration, pairing_enabled: binding.pairingEnabled,
      capabilities: binding.capabilities, path_hints: binding.pathHints, revoked: binding.revokedAt !== null,
      updated_at: new Date(binding.updatedAt).toISOString(),
    };
  }
}
