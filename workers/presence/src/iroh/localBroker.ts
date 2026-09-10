import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import { and, desc, eq, inArray, isNull } from "drizzle-orm";
import { Effect } from "effect";
import { accountBindings, accountChallenges, accountPreferences, accountMeta, accountDrizzleSchema } from "../accountDrizzleSchema";
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
import { bindingMatchesDiscoveryScope, irohDiscoveryScopeJSON, parseIrohDiscoveryScope, type IrohDiscoveryScope } from "./discoveryScope";
import { z } from "zod";

export type LocalIrohConfig = {
  readonly lanDiscoverySecretBase64: string;
  readonly accountSubjectSecretBase64?: string;
  readonly grantVerificationKeys: unknown;
  readonly grantSigningPrivateKeyPem?: string;
  readonly grantSigningKid?: string;
  readonly relayMinterUrl?: string;
  readonly relayMinterHmacSecretBase64?: string;
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

const relayPreferenceSchema = z.strictObject({
  mode: z.enum(["automatic", "managed", "custom"]),
  selectedManagedRelayIds: z.array(z.string().regex(/^[a-z0-9][a-z0-9._-]{0,62}[a-z0-9]$/).max(64)).max(16),
  customRelays: z.array(z.strictObject({
    id: z.string().regex(/^[a-z0-9][a-z0-9._-]{0,62}[a-z0-9]$/).max(64),
    provider: z.string().min(1).max(80), region: z.string().min(1).max(80),
    url: z.string().url().max(2_048), displayName: z.string().min(1).max(100).optional(),
    authMode: z.enum(["none", "device_secret"]),
  })).max(16),
}).superRefine((value, ctx) => {
  if (value.mode === "managed" && value.selectedManagedRelayIds.length === 0) ctx.addIssue({ code: "custom", path: ["selectedManagedRelayIds"], message: "managed requires a relay" });
  if (value.mode === "custom" && value.customRelays.length === 0) ctx.addIssue({ code: "custom", path: ["customRelays"], message: "custom requires a relay" });
  if (new Set(value.selectedManagedRelayIds).size !== value.selectedManagedRelayIds.length) ctx.addIssue({ code: "custom", path: ["selectedManagedRelayIds"], message: "duplicate relay" });
  if (new Set(value.customRelays.map((relay) => relay.id)).size !== value.customRelays.length || new Set(value.customRelays.map((relay) => relay.url)).size !== value.customRelays.length) ctx.addIssue({ code: "custom", path: ["customRelays"], message: "duplicate relay" });
});
type RelayPreference = z.infer<typeof relayPreferenceSchema>;
const defaultRelayPreference: RelayPreference = { mode: "automatic", selectedManagedRelayIds: [], customRelays: [] };

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
        assertChallengeMatchesPayload(challenge, decoded.payload);
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
        const revision = this.bumpRevision(now);
        return { revision, binding: this.publicBinding(binding), relay: { status: "not_requested" as const }, discovery: this.discovery(userId, namespace, now), discovery_complete: true };
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

  getRelayPreference(_userId: string) {
    return Effect.try({
      try: () => {
        const row = this.db.select().from(accountPreferences).where(eq(accountPreferences.preferenceKey, "relay")).get();
        if (!row) return { preference: defaultRelayPreference, preferenceRevision: 0 };
        const stored = JSON.parse(row.payload) as { preference?: unknown; revision?: unknown };
        const parsed = relayPreferenceSchema.safeParse(stored.preference ?? stored);
        const revision = stored.preference === undefined ? 0 : stored.revision;
        if (!parsed.success || typeof revision !== "number" || !Number.isSafeInteger(revision) || revision < 0) {
          throw new IrohInvalidInputError({ code: "invalid_persisted_preference" });
        }
        return { preference: parsed.data, preferenceRevision: revision };
      },
      catch: (error) => error,
    });
  }

  setRelayPreference(_userId: string, raw: unknown, now = Date.now()) {
    return Effect.try({
      try: () => {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new IrohInvalidInputError({ code: "invalid_preference" });
        const body = raw as Record<string, unknown>;
        const keys = Object.keys(body);
        if (keys.some((key) => key !== "expectedRevision" && key !== "preference")) throw new IrohInvalidInputError({ code: "invalid_preference" });
        const expected = body.expectedRevision;
        if (expected !== undefined && (!Number.isSafeInteger(expected) || (expected as number) < 0)) throw new IrohInvalidInputError({ code: "invalid_preference" });
        const parsed = relayPreferenceSchema.safeParse(body.preference);
        if (!parsed.success) throw new IrohInvalidInputError({ code: "invalid_preference" });
        const current = Effect.runSync(this.getRelayPreference(_userId));
        if (expected !== undefined && expected !== current.preferenceRevision) throw new IrohConflictError({ code: "preference_conflict" });
        const revision = current.preferenceRevision + 1;
        const payload = JSON.stringify({ preference: parsed.data, revision });
        const values = { preferenceKey: "relay" as const, payload, payloadBytes: new TextEncoder().encode(payload).byteLength, updatedAt: now };
        this.db.insert(accountPreferences).values(values).onConflictDoUpdate({ target: accountPreferences.preferenceKey, set: { payload, payloadBytes: values.payloadBytes, updatedAt: now } }).run();
        return { preference: parsed.data, preferenceRevision: revision };
      },
      catch: (error) => error,
    });
  }

  syncConnectivity(userId: string, raw: unknown, namespace = "legacy", now = Date.now()) {
    return Effect.try({
      try: () => {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new IrohInvalidInputError({ code: "invalid_request" });
        const body = raw as Record<string, unknown>;
        const protocol = body.protocol_version;
        if (protocol !== 2 && protocol !== 3) throw new IrohInvalidInputError({ code: "unsupported_protocol" });
        const known = body.known_revision;
        if (known !== undefined && known !== null && (!Number.isSafeInteger(known) || (known as number) < 0)) throw new IrohInvalidInputError({ code: "invalid_revision" });
        const scope = protocol === 3 ? parseIrohDiscoveryScope(body.discovery_scope) : undefined;
        const discovery = this.discovery(userId, namespace, now, scope);
        const changed = known === null || known === undefined || known !== discovery.revision;
        return {
          protocol_version: protocol, revision: discovery.revision, changed, reset: typeof known === "number" && known > discovery.revision,
          ...(changed ? { snapshot: discovery } : {}),
          ...(protocol === 2
            ? (changed ? { snapshot_complete: true } : {})
            : { discovery_scope: irohDiscoveryScopeJSON(scope!), ...(changed ? { snapshot_scope_complete: true } : {}) }),
        };
      },
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
        return { revoked: true, revision: this.bumpRevision(now), lan_rendezvous_rotated: true };
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

  async issueRelayToken(userId: string, raw: unknown, now = Date.now(), namespace = "legacy", proof?: IrohBindingRequestProof) {
    const body = raw as { endpointId?: unknown };
    if (typeof body.endpointId !== "string") throw new IrohInvalidInputError({ code: "invalid_endpoint_id" });
    const binding = this.db.select().from(accountBindings).where(and(eq(accountBindings.endpointId, body.endpointId), eq(accountBindings.clientNamespace, namespace), isNull(accountBindings.revokedAt))).get();
    if (!binding) throw new IrohNotFoundError({ resource: "binding" });
    const local = this.readBinding(binding.bindingId, userId);
    if (proof) verifyBindingRequestSignature({ ...proof, endpointId: local.endpointId, nowSeconds: Math.floor(now / 1000) });
    if (!this.config.relayMinterUrl || !this.config.relayMinterHmacSecretBase64) throw new IrohForbiddenError({ code: "relay_minter_not_configured" });
    const bodyText = JSON.stringify({ endpointId: local.endpointId, lifetimeSeconds: 24 * 60 * 60 });
    const url = new URL(this.config.relayMinterUrl);
    const timestamp = String(Math.floor(now / 1000));
    const bodyHash = createHash("sha256").update(bodyText).digest("hex");
    const secret = Buffer.from(this.config.relayMinterHmacSecretBase64, "base64");
    const signature = createHmac("sha256", secret).update(`POST\n${url.pathname}\n${timestamp}\n${bodyHash}`).digest("base64url");
    const response = await fetch(url, { method: "POST", redirect: "error", signal: AbortSignal.timeout(10_000), headers: { "content-type": "application/json", "x-cmux-iroh-timestamp": timestamp, "x-cmux-iroh-signature": signature }, body: bodyText });
    if (!response.ok) throw new IrohForbiddenError({ code: "relay_minter_rejected" });
    const result = await response.json() as { token?: unknown; expiresAt?: unknown };
    if (typeof result.token !== "string" || typeof result.expiresAt !== "string") throw new IrohInvalidInputError({ code: "invalid_relay_minter_response" });
    return { token: result.token, expires_at: result.expiresAt, refresh_after: new Date(now + 12 * 60 * 60 * 1000).toISOString(), relay_fleet: MANAGED_RELAY_URLS };
  }

  private discovery(userId: string, namespace: string, now: number, scope?: IrohDiscoveryScope) {
    const rows = this.db.select().from(accountBindings).where(and(eq(accountBindings.clientNamespace, namespace), isNull(accountBindings.revokedAt))).all();
    const bindings = rows.map((row) => this.readBinding(row.bindingId, userId)).filter((binding) => !scope || bindingMatchesDiscoveryScope(binding, scope)).map((binding) => this.publicBinding(binding, now));
    const revisionRow = this.db.select().from(accountMeta).where(eq(accountMeta.key, "route_revision")).get();
    const persistedRevision = revisionRow ? Number(revisionRow.value) : 0;
    const revision = Number.isSafeInteger(persistedRevision) && persistedRevision >= 0 ? persistedRevision : 0;
    const generation = 1;
    const rendezvous = deriveLanRendezvousKey(this.config.lanDiscoverySecretBase64, userId, generation);
    return { route_contract_version: 1, revision, bindings, relay_fleet: MANAGED_RELAY_URLS, lan_rendezvous: { generation, key: rendezvous }, grant_verification_keys: this.config.grantVerificationKeys };
  }

  private bumpRevision(now: number): number {
    const row = this.db.select().from(accountMeta).where(eq(accountMeta.key, "route_revision")).get();
    const current = row ? Number(row.value) : 0;
    const revision = Math.max(Number.isSafeInteger(current) && current >= 0 ? current + 1 : 1, now);
    this.db.insert(accountMeta).values({ key: "route_revision", value: String(revision) }).onConflictDoUpdate({ target: accountMeta.key, set: { value: String(revision) } }).run();
    return revision;
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
