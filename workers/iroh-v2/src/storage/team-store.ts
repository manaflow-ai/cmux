import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/durable-sqlite";
import { DeviceDescriptorSchema, identifier, type DeviceDescriptor, type DeviceMetadata, type DeviceRecord, type Identity, type Permission } from "../contracts/common";
import { OperationError } from "../errors";
import { applyStorageMigrations } from "./migrations";
import { storageSchema } from "./schema";

export type TeamScope = Readonly<{ environment: string; projectId: string; teamId: string }>;

type DeviceRow = {
  identity_key: string; device_record_id: string; environment: string; project_id: string; team_id: string;
  user_id: string; device_id: string; app_namespace: string; build_tag: string; endpoint_id: string;
  identity_generation: number; platform: "mac" | "ios"; display_name: string; app_version: string;
  pairing_enabled: number; capabilities_json: string; relay_urls_json: string; revoked: number;
  revision: number; created_at: number; updated_at: number;
};

type ChallengeRow = { identity_key: string; challenge_id: string; nonce_hash: string; payload_hash: string; expires_at: number; issued_at: number };
type ReceiptRow = { request_id: string; identity_key: string; request_hash: string; device_json: string; created_at: number };

export type RegistrationCommit = Readonly<{
  descriptor: DeviceDescriptor;
  challengeId: string;
  nonceHash: string;
  payloadHash: string;
  requestId: string;
  requestHash: string;
  now: number;
}>;

export type RegistrationResult = Readonly<{ device: DeviceRecord; idempotent: boolean }>;
export type ChallengeIssue = Readonly<{ challengeId: string; nonceHash: string; payloadHash: string; expiresAt: number }>;
export const DEVICE_PROOF_WINDOW_SECONDS = 60;
export const AUTHORITY_LEASE_SECONDS = 3600;
const DEVICE_PROOF_RING_LIMIT = 256;

function identityKey(identity: Identity): string {
  return JSON.stringify([identity.environment, identity.projectId, identity.teamId, identity.userId, identity.deviceId, identity.appNamespace, identity.buildTag]);
}

function assertScope(scope: TeamScope, identity: Identity): void {
  if (identity.environment !== scope.environment || identity.projectId !== scope.projectId || identity.teamId !== scope.teamId) {
    throw new OperationError("environment_mismatch", 403);
  }
}

function rowToDevice(row: DeviceRow): DeviceRecord {
  const descriptor = DeviceDescriptorSchema.parse({
    identity: { environment: row.environment, projectId: row.project_id, teamId: row.team_id, userId: row.user_id, deviceId: row.device_id, appNamespace: row.app_namespace, buildTag: row.build_tag },
    endpointId: row.endpoint_id,
    identityGeneration: row.identity_generation,
    metadata: { platform: row.platform, displayName: row.display_name, appVersion: row.app_version, pairingEnabled: row.pairing_enabled === 1, capabilities: JSON.parse(row.capabilities_json), relayURLs: JSON.parse(row.relay_urls_json) },
  });
  return { deviceRecordId: row.device_record_id, descriptor, revision: row.revision, revoked: row.revoked === 1 };
}

function toColumns(descriptor: DeviceDescriptor): Record<string, string | number | boolean> {
  const { identity, metadata } = descriptor;
  return {
    identity_key: identityKey(identity), device_record_id: descriptor.endpointId,
    environment: identity.environment, project_id: identity.projectId, team_id: identity.teamId,
    user_id: identity.userId, device_id: identity.deviceId, app_namespace: identity.appNamespace,
    build_tag: identity.buildTag, endpoint_id: descriptor.endpointId, identity_generation: descriptor.identityGeneration,
    platform: metadata.platform, display_name: metadata.displayName, app_version: metadata.appVersion,
    pairing_enabled: metadata.pairingEnabled ? 1 : 0, capabilities_json: JSON.stringify(metadata.capabilities), relay_urls_json: JSON.stringify(metadata.relayURLs),
  };
}

export class TeamStore {
  readonly #db;
  constructor(readonly storage: DurableObjectStorage, readonly scope: TeamScope, options?: { initialize?: boolean }) {
    this.#db = drizzle(storage, { schema: storageSchema });
    if (options?.initialize !== false) applyStorageMigrations(storage);
  }

  initialize(now = Date.now()): void { applyStorageMigrations(this.storage, now); }

  readRevision(): number {
    const row = this.#db.get<{ revision: number }>(sql`SELECT "revision" FROM "team_meta" WHERE "id" = 1`);
    return row?.revision ?? 0;
  }

  getAuthority(userId: string): { userId: string; verifiedAt: number; expiresAt: number } | null {
    identifier.parse(userId);
    const row = this.#db.get<{ user_id: string; verified_at: number; expires_at: number }>(sql`SELECT "user_id", "verified_at", "expires_at" FROM "user_authority" WHERE "user_id" = ${userId}`);
    return row ? { userId: row.user_id, verifiedAt: row.verified_at, expiresAt: row.expires_at } : null;
  }

  observeAuthority(userId: string, verifiedAt: number, expiresAt: number, now: number): number | null {
    identifier.parse(userId);
    if (!Number.isSafeInteger(verifiedAt) || !Number.isSafeInteger(expiresAt) || !Number.isSafeInteger(now)) throw new OperationError("invalid_request", 400);
    if (verifiedAt > now + 30 || expiresAt !== verifiedAt + AUTHORITY_LEASE_SECONDS || expiresAt <= now) throw new OperationError("invalid_request", 400);
    return this.storage.transactionSync(() => {
      const current = this.getAuthority(userId);
      if (current && verifiedAt <= current.verifiedAt) return null;
      const revision = this.readRevision() + 1;
      this.#db.run(sql`INSERT INTO "user_authority" ("user_id", "verified_at", "expires_at") VALUES (${userId}, ${verifiedAt}, ${expiresAt}) ON CONFLICT ("user_id") DO UPDATE SET "verified_at" = excluded."verified_at", "expires_at" = excluded."expires_at"`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${revision} WHERE "id" = 1`);
      this.appendAudit("user.authority.observed", userId, userId, revision, now, { verifiedAt, expiresAt });
      return revision;
    });
  }

  getRelayPreferences(): { relayURLs: string[]; revision: number } {
    const row = this.#db.get<{ relay_urls_json: string; revision: number }>(sql`SELECT "relay_urls_json", "revision" FROM "team_preferences" WHERE "id" = 1`);
    return row ? { relayURLs: JSON.parse(row.relay_urls_json) as string[], revision: row.revision } : { relayURLs: [], revision: this.readRevision() };
  }

  updateRelayPreferences(relayURLs: string[], expectedRevision: number, actorUserId: string, now: number): number {
    return this.storage.transactionSync(() => {
      const current = this.getRelayPreferences();
      if (current.revision !== expectedRevision) throw new OperationError("revision_conflict", 409, true);
      const revision = this.readRevision() + 1;
      this.#db.run(sql`INSERT INTO "team_preferences" ("id", "relay_urls_json", "revision", "updated_at") VALUES (1, ${JSON.stringify(relayURLs)}, ${revision}, ${now}) ON CONFLICT ("id") DO UPDATE SET "relay_urls_json" = excluded."relay_urls_json", "revision" = excluded."revision", "updated_at" = excluded."updated_at"`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${revision} WHERE "id" = 1`);
      this.appendAudit("team.preferences.updated", actorUserId, this.scope.teamId, revision, now, { relayURLs });
      return revision;
    });
  }

  private appendAudit(eventType: string, actorUserId: string, targetId: string, revision: number, now: number, detail: unknown): void {
    this.#db.run(sql`INSERT INTO "authority_audit" ("event_type", "actor_user_id", "target_id", "revision", "created_at", "detail_json") VALUES (${eventType}, ${actorUserId}, ${targetId}, ${revision}, ${now}, ${JSON.stringify(detail)})`);
  }

  /**
   * Atomically checks the enrolled identity and consumes a signed request id.
   * The bounded replay ring is pruned only when used, never by an alarm.
   */
  consumeDeviceProof(input: Readonly<{ identity: Identity; endpointId: string; identityGeneration: number; requestId: string; issuedAt: number; now: number }>): void {
    assertScope(this.scope, input.identity);
    const key = identityKey(input.identity);
    if (!input.requestId || Math.abs(input.now - input.issuedAt) > DEVICE_PROOF_WINDOW_SECONDS) throw new OperationError("invalid_device_proof", 401);
    this.storage.transactionSync(() => {
      const device = this.#db.get<{ endpoint_id: string; identity_generation: number; revoked: number }>(sql`SELECT "endpoint_id", "identity_generation", "revoked" FROM "devices" WHERE "identity_key" = ${key}`);
      if (!device) throw new OperationError("device_not_enrolled", 409);
      if (device.revoked === 1) throw new OperationError("device_revoked", 403);
      if (device.endpoint_id !== input.endpointId || device.identity_generation !== input.identityGeneration) throw new OperationError("identity_mismatch", 401);
      this.#db.run(sql`DELETE FROM "device_proof_replays" WHERE "identity_key" = ${key} AND "expires_at" <= ${input.now}`);
      const existing = this.#db.get<{ request_id: string }>(sql`SELECT "request_id" FROM "device_proof_replays" WHERE "identity_key" = ${key} AND "request_id" = ${input.requestId}`);
      if (existing) throw new OperationError("proof_replayed", 409);
      const count = this.#db.get<{ count: number }>(sql`SELECT count(*) AS "count" FROM "device_proof_replays" WHERE "identity_key" = ${key}`)?.count ?? 0;
      if (count >= DEVICE_PROOF_RING_LIMIT) throw new OperationError("rate_limited", 429, true, DEVICE_PROOF_WINDOW_SECONDS * 1000);
      // Keep the row one extra second so a proof accepted at the exact ±60s boundary cannot be replayed.
      this.#db.run(sql`INSERT INTO "device_proof_replays" ("identity_key", "request_id", "issued_at", "expires_at") VALUES (${key}, ${input.requestId}, ${input.issuedAt}, ${input.issuedAt + DEVICE_PROOF_WINDOW_SECONDS + 1})`);
    });
  }

  getDevice(identity: Identity): DeviceRecord | null {
    assertScope(this.scope, identity);
    const row = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "identity_key" = ${identityKey(identity)}`);
    return row ? rowToDevice(row) : null;
  }

  getDeviceByRecordId(deviceRecordId: string): DeviceRecord | null {
    const row = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "device_record_id" = ${deviceRecordId}`);
    return row ? rowToDevice(row) : null;
  }

  /** Directory visibility is explicit: owner devices plus rows with connect permission. */
  listVisibleDevices(requestingUserId: string, afterRecordId?: string, limit = 1024): DeviceRecord[] {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1024) throw new OperationError("invalid_request", 400);
    const rows = afterRecordId === undefined ? this.#db.all<DeviceRow>(sql`
      SELECT d.* FROM "devices" d
      LEFT JOIN "permissions" p ON p."device_record_id" = d."device_record_id" AND p."subject_user_id" = ${requestingUserId}
      WHERE d."user_id" = ${requestingUserId} OR p."connect" = 1
      ORDER BY d."device_record_id"
      LIMIT ${limit}`) : this.#db.all<DeviceRow>(sql`
      SELECT d.* FROM "devices" d
      LEFT JOIN "permissions" p ON p."device_record_id" = d."device_record_id" AND p."subject_user_id" = ${requestingUserId}
      WHERE (d."user_id" = ${requestingUserId} OR p."connect" = 1) AND d."device_record_id" > ${afterRecordId}
      ORDER BY d."device_record_id"
      LIMIT ${limit}`);
    return rows.map(rowToDevice);
  }

  /** One ordered page for outbound discovery and permissions to enter this Mac. */
  listDirectoryDevices(requester: DeviceRecord, now: number, afterRecordId?: string, limit = 1024): {
    device: DeviceRecord; visible: boolean; inboundPermissionExpiresAt: number | null;
  }[] {
    assertScope(this.scope, requester.descriptor.identity);
    if (!Number.isSafeInteger(now) || !Number.isSafeInteger(limit) || limit < 1 || limit > 1024) throw new OperationError("invalid_request", 400);
    const userId = requester.descriptor.identity.userId;
    const acceptsPeers = !requester.revoked && requester.descriptor.metadata.platform === "mac" && requester.descriptor.metadata.pairingEnabled;
    const visible = sql`(d."user_id" = ${userId} OR outgoing."connect" = 1)`;
    const inbound = sql`(${acceptsPeers ? 1 : 0} = 1 AND d."platform" = 'ios' AND d."revoked" = 0
      AND a."expires_at" > ${now} AND (d."user_id" = ${userId} OR incoming."connect" = 1))`;
    const rows = this.#db.all<DeviceRow & { visible: number; inbound_expires_at: number | null }>(sql`
      SELECT d.*, CASE WHEN ${visible} THEN 1 ELSE 0 END AS "visible",
        CASE WHEN ${inbound} THEN a."expires_at" ELSE NULL END AS "inbound_expires_at"
      FROM "devices" d
      LEFT JOIN "permissions" outgoing ON outgoing."device_record_id" = d."device_record_id" AND outgoing."subject_user_id" = ${userId}
      LEFT JOIN "permissions" incoming ON incoming."device_record_id" = ${requester.deviceRecordId} AND incoming."subject_user_id" = d."user_id"
      LEFT JOIN "user_authority" a ON a."user_id" = d."user_id"
      WHERE (${visible} OR ${inbound}) AND d."device_record_id" > ${afterRecordId ?? ""}
      ORDER BY d."device_record_id" LIMIT ${limit}`);
    return rows.map(row => ({ device: rowToDevice(row), visible: row.visible === 1, inboundPermissionExpiresAt: row.inbound_expires_at }));
  }

  issueChallenge(identity: Identity, issue: ChallengeIssue & { issuedAt?: number }): ChallengeIssue {
    assertScope(this.scope, identity);
    const key = identityKey(identity);
    const issuedAt = issue.issuedAt ?? Math.max(0, issue.expiresAt - 30 * 60);
    if (issue.expiresAt <= issuedAt) throw new OperationError("challenge_invalid", 400);
    this.storage.transactionSync(() => {
      const exists = this.#db.get<{ identity_key: string }>(sql`SELECT "identity_key" FROM "pending_challenges" WHERE "identity_key" = ${key}`);
      const count = this.#db.get<{ count: number }>(sql`SELECT count(*) AS "count" FROM "pending_challenges"` )?.count ?? 0;
      if (!exists && count >= 4096) throw new OperationError("storage_limit", 507, true, 60_000);
      this.#db.run(sql`INSERT INTO "pending_challenges" ("identity_key", "challenge_id", "nonce_hash", "payload_hash", "expires_at", "issued_at") VALUES (${key}, ${issue.challengeId}, ${issue.nonceHash}, ${issue.payloadHash}, ${issue.expiresAt}, ${issuedAt}) ON CONFLICT ("identity_key") DO UPDATE SET "challenge_id" = excluded."challenge_id", "nonce_hash" = excluded."nonce_hash", "payload_hash" = excluded."payload_hash", "expires_at" = excluded."expires_at", "issued_at" = excluded."issued_at"`);
    });
    return { challengeId: issue.challengeId, nonceHash: issue.nonceHash, payloadHash: issue.payloadHash, expiresAt: issue.expiresAt };
  }

  /** Read-only preflight used before reserving a global EndpointID. commitRegistration rechecks it. */
  validateRegistrationChallenge(input: RegistrationCommit): void {
    const descriptor = DeviceDescriptorSchema.parse(input.descriptor);
    assertScope(this.scope, descriptor.identity);
    const row = this.#db.get<ChallengeRow>(sql`SELECT * FROM "pending_challenges" WHERE "identity_key" = ${identityKey(descriptor.identity)}`);
    if (!row) throw new OperationError("challenge_missing", 409);
    if (row.challenge_id !== input.challengeId) throw new OperationError("challenge_replaced", 409);
    if (row.nonce_hash !== input.nonceHash || row.payload_hash !== input.payloadHash) throw new OperationError("challenge_invalid", 400);
    if (row.expires_at <= input.now) throw new OperationError("challenge_expired", 409);
  }

  findRegistrationReceipt(identity: Identity, requestId: string, requestHash: string): RegistrationResult | null {
    assertScope(this.scope, identity);
    const key = identityKey(identity);
    const prior = this.#db.get<ReceiptRow>(sql`SELECT * FROM "registration_receipts" WHERE "identity_key" = ${key} AND "request_id" = ${requestId} AND "request_hash" = ${requestHash}`);
    if (!prior) return null;
    const current = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "identity_key" = ${key}`);
    if (!current || current.revoked === 1) return null;
    const device = JSON.parse(prior.device_json) as DeviceRecord;
    if (current.endpoint_id !== device.descriptor.endpointId || current.identity_generation !== device.descriptor.identityGeneration) return null;
    return { device, idempotent: true };
  }

  /**
   * The only enrollment write. Proof is checked by the caller and all proof
   * material is checked again here in the same transaction as consuming the
   * challenge, writing the device, receipt and revision.
   */
  commitRegistration(input: RegistrationCommit): RegistrationResult {
    const descriptor = DeviceDescriptorSchema.parse(input.descriptor);
    assertScope(this.scope, descriptor.identity);
    if (!input.requestId || !input.requestHash) throw new OperationError("invalid_request", 400);
    const key = identityKey(descriptor.identity);
    return this.storage.transactionSync(() => {
      const prior = this.#db.get<ReceiptRow>(sql`SELECT * FROM "registration_receipts" WHERE "request_id" = ${input.requestId}`);
      if (prior) {
        if (prior.identity_key !== key || prior.request_hash !== input.requestHash) throw new OperationError("proof_replayed", 409);
        const current = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "identity_key" = ${key}`);
        if (!current || current.revoked === 1) throw new OperationError(current?.revoked === 1 ? "device_revoked" : "device_not_enrolled", 409);
        if (current.endpoint_id !== descriptor.endpointId || current.identity_generation !== descriptor.identityGeneration) throw new OperationError("key_replacement_required", 409);
        return { device: JSON.parse(prior.device_json) as DeviceRecord, idempotent: true };
      }
      const challenge = this.#db.get<ChallengeRow>(sql`SELECT * FROM "pending_challenges" WHERE "identity_key" = ${key}`);
      if (!challenge) throw new OperationError("challenge_missing", 409);
      if (challenge.challenge_id !== input.challengeId) throw new OperationError("challenge_replaced", 409);
      if (challenge.nonce_hash !== input.nonceHash || challenge.payload_hash !== input.payloadHash) throw new OperationError("challenge_invalid", 400);
      if (challenge.expires_at <= input.now) throw new OperationError("challenge_expired", 409);
      const existing = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "identity_key" = ${key}`);
      if (existing && (existing.endpoint_id !== descriptor.endpointId || existing.identity_generation !== descriptor.identityGeneration || existing.revoked === 1)) {
        throw new OperationError(existing.revoked === 1 ? "device_revoked" : "key_replacement_required", 409);
      }
      const nextRevision = this.readRevision() + 1;
      const record: DeviceRecord = {
        deviceRecordId: existing?.device_record_id ?? crypto.randomUUID(), descriptor, revision: nextRevision, revoked: false,
      };
      const c = toColumns(descriptor);
      if (existing) {
        this.#db.run(sql`UPDATE "devices" SET "display_name" = ${c.display_name}, "app_version" = ${c.app_version}, "pairing_enabled" = ${c.pairing_enabled}, "capabilities_json" = ${c.capabilities_json}, "relay_urls_json" = ${c.relay_urls_json}, "revision" = ${nextRevision}, "updated_at" = ${input.now}, "revoked" = 0 WHERE "identity_key" = ${key}`);
      } else {
        this.#db.run(sql`INSERT INTO "devices" ("identity_key", "device_record_id", "environment", "project_id", "team_id", "user_id", "device_id", "app_namespace", "build_tag", "endpoint_id", "identity_generation", "platform", "display_name", "app_version", "pairing_enabled", "capabilities_json", "relay_urls_json", "revoked", "revision", "created_at", "updated_at") VALUES (${key}, ${record.deviceRecordId}, ${c.environment}, ${c.project_id}, ${c.team_id}, ${c.user_id}, ${c.device_id}, ${c.app_namespace}, ${c.build_tag}, ${c.endpoint_id}, ${c.identity_generation}, ${c.platform}, ${c.display_name}, ${c.app_version}, ${c.pairing_enabled}, ${c.capabilities_json}, ${c.relay_urls_json}, 0, ${nextRevision}, ${input.now}, ${input.now})`);
      }
      this.#db.run(sql`DELETE FROM "pending_challenges" WHERE "identity_key" = ${key} AND "challenge_id" = ${input.challengeId} AND "nonce_hash" = ${input.nonceHash} AND "payload_hash" = ${input.payloadHash} AND "expires_at" > ${input.now}`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${nextRevision} WHERE "id" = 1`);
      this.#db.run(sql`INSERT INTO "registration_receipts" ("identity_key", "request_id", "request_hash", "device_json", "created_at") VALUES (${key}, ${input.requestId}, ${input.requestHash}, ${JSON.stringify(record)}, ${input.now}) ON CONFLICT ("identity_key") DO UPDATE SET "request_id" = excluded."request_id", "request_hash" = excluded."request_hash", "device_json" = excluded."device_json", "created_at" = excluded."created_at"`);
      this.appendAudit(existing ? "device.registration.updated" : "device.enrolled", descriptor.identity.userId, record.deviceRecordId, nextRevision, input.now, { identityGeneration: descriptor.identityGeneration });
      return { device: record, idempotent: false };
    });
  }

  updateMetadata(identity: Identity, metadata: DeviceMetadata, now: number): DeviceRecord {
    assertScope(this.scope, identity);
    const key = identityKey(identity);
    return this.storage.transactionSync(() => {
      const existing = this.#db.get<DeviceRow>(sql`SELECT * FROM "devices" WHERE "identity_key" = ${key}`);
      if (!existing) throw new OperationError("device_not_enrolled", 409);
      if (existing.revoked === 1) throw new OperationError("device_revoked", 403);
      const revision = this.readRevision() + 1;
      this.#db.run(sql`UPDATE "devices" SET "display_name" = ${metadata.displayName}, "app_version" = ${metadata.appVersion}, "pairing_enabled" = ${metadata.pairingEnabled ? 1 : 0}, "capabilities_json" = ${JSON.stringify(metadata.capabilities)}, "relay_urls_json" = ${JSON.stringify(metadata.relayURLs)}, "revision" = ${revision}, "updated_at" = ${now} WHERE "identity_key" = ${key}`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${revision} WHERE "id" = 1`);
      return { ...rowToDevice({ ...existing, display_name: metadata.displayName, app_version: metadata.appVersion, pairing_enabled: metadata.pairingEnabled ? 1 : 0, capabilities_json: JSON.stringify(metadata.capabilities), relay_urls_json: JSON.stringify(metadata.relayURLs), revision, updated_at: now }), revision };
    });
  }

  revokeDevice(deviceRecordId: string, now: number, actorUserId = "system"): number {
    return this.storage.transactionSync(() => {
      const revision = this.readRevision() + 1;
      this.#db.run(sql`UPDATE "devices" SET "revoked" = 1, "revision" = ${revision}, "updated_at" = ${now} WHERE "device_record_id" = ${deviceRecordId}`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${revision} WHERE "id" = 1`);
      this.appendAudit("device.revoked", actorUserId, deviceRecordId, revision, now, {});
      return revision;
    });
  }

  getPermission(subjectUserId: string, deviceRecordId: string): Permission | null {
    const row = this.#db.get<{ subject_user_id: string; device_record_id: string; connect: number; manage: number }>(sql`SELECT * FROM "permissions" WHERE "subject_user_id" = ${subjectUserId} AND "device_record_id" = ${deviceRecordId}`);
    return row ? { subjectUserId: row.subject_user_id, deviceRecordId: row.device_record_id, connect: row.connect === 1, manage: row.manage === 1 } : null;
  }

  setPermission(permission: Permission, now: number, actorUserId = "system"): number {
    return this.storage.transactionSync(() => {
      const revision = this.readRevision() + 1;
      this.#db.run(sql`INSERT INTO "permissions" ("subject_user_id", "device_record_id", "connect", "manage", "updated_at") VALUES (${permission.subjectUserId}, ${permission.deviceRecordId}, ${permission.connect ? 1 : 0}, ${permission.manage ? 1 : 0}, ${now}) ON CONFLICT ("subject_user_id", "device_record_id") DO UPDATE SET "connect" = excluded."connect", "manage" = excluded."manage", "updated_at" = excluded."updated_at"`);
      this.#db.run(sql`UPDATE "team_meta" SET "revision" = ${revision} WHERE "id" = 1`);
      this.appendAudit("permission.updated", actorUserId, permission.deviceRecordId, revision, now, { subjectUserId: permission.subjectUserId, connect: permission.connect, manage: permission.manage });
      return revision;
    });
  }
}

export { identityKey };
