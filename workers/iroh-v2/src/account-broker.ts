import type { VerifiedAuthority } from "./auth";
import { parseInput } from "./boundary";
import { ACCOUNT_INBOUND_GRANT_SECONDS, ACCOUNT_RECORD_BYTES, accountRequest, type AccountDirectory, type AccountRequest, type AccountResponse } from "./contracts/account";
import type { DeviceRecord, Identity } from "./contracts/common";
import type { SocketSetup } from "./contracts/requests";
import { API_TICKET_SECONDS, accountRequestSigningInput, verifyDeviceSignature } from "./crypto";
import { OperationError } from "./errors";
import { ACCOUNT_DIRECTORY_RULES } from "./rules";
import { installationKey, type AccountMacRow, type AccountRevalidation, type AccountStore } from "./storage/account-store";
import { identityKey } from "./storage/team-store";

export const MAC_HOST_CAPABILITY = "cmux.mac-host.v1";
export const MAC_DEVICES_CAPABILITY = "cmux.mac-devices.v1";

/** What TeamControl.accountMacRecords returns for one identity. */
export type AccountMacRecord = { device: DeviceRecord; authorityExpiresAt: number | null };

export interface AccountSession {
  readonly sessionId: string;
  readonly userId: string;
  readonly identity: Identity;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly expiresAt: number;
}

export interface AccountDependencies {
  readonly store: AccountStore;
  readonly userId: string;
  readonly now: () => number;
  readonly relayURLs: readonly string[];
  /** Read-only team RPC, batched per team. Failures surface as a retryable outage, never as an empty directory. */
  readonly teamRecords: (teamId: string, identities: Identity[]) => Promise<(AccountMacRecord | null)[]>;
}

export interface AccountResult {
  readonly response: AccountResponse;
  /** The new account revision when the directory changed; the adapter broadcasts it. */
  readonly changed?: number;
}

/** resync_required that may follow a committed account change the adapter must still announce. */
export class AccountResyncError extends OperationError {
  constructor(readonly changed: number | undefined) { super("resync_required", 409, true); }
}

/** A directory page stays under the 64 KiB frame bound with room for the envelope. */
const ACCOUNT_PAGE_BYTES = 60 * 1024;

function recordBytes(record: DeviceRecord): number {
  return new TextEncoder().encode(JSON.stringify(record)).byteLength;
}

function isMacPeer(record: DeviceRecord): boolean {
  const { platform, capabilities } = record.descriptor.metadata;
  return platform === "mac" && (capabilities.includes(MAC_HOST_CAPABILITY) || capabilities.includes(MAC_DEVICES_CAPABILITY));
}

/** The one eligibility rule for publish, directory rows and team-change revalidation. */
function assertEligible(record: AccountMacRecord | null, expected: { endpointId: string; identityGeneration: number }): AccountMacRecord {
  if (!record) throw new OperationError("device_not_enrolled", 409);
  if (record.device.revoked) throw new OperationError("device_revoked", 403);
  const descriptor = record.device.descriptor;
  if (descriptor.endpointId !== expected.endpointId || descriptor.identityGeneration !== expected.identityGeneration) {
    throw new OperationError("key_replacement_required", 409);
  }
  if (!isMacPeer(record.device)) throw new OperationError("permission_denied", 403);
  return record;
}

function eligible(record: AccountMacRecord | null, expected: { endpointId: string; identityGeneration: number }): record is AccountMacRecord {
  try { assertEligible(record, expected); return true; } catch { return false; }
}

/**
 * Per-user Mac directory. The user comes only from verified ticket claims; a
 * row exists only while its team still holds a matching, unrevoked Mac record,
 * and every read re-checks that against the team objects.
 */
export class AccountBroker {
  /** Team-change notices seen by this object instance; see `consistent`. */
  private notices = 0;
  /** Serializes team notices; see `teamChanged`. */
  private noticeTail: Promise<void> = Promise.resolve();
  constructor(readonly dependencies: AccountDependencies) {}

  /**
   * Verifies the account-purpose device proof and consumes its nonce. `request`
   * is undefined for a socket open, whose proof covers the setup alone.
   */
  async authorize(setup: SocketSetup, request: unknown, authority: VerifiedAuthority, expiresAt: number): Promise<{ session: AccountSession; request?: AccountRequest }> {
    const identity = setup.device.identity;
    if (authority.userId !== this.dependencies.userId || identity.userId !== authority.userId || identity.teamId !== authority.teamId
      || identity.environment !== authority.environment || identity.projectId !== authority.projectId) {
      throw new OperationError("identity_mismatch", 403);
    }
    const now = this.dependencies.now();
    if (expiresAt <= now) throw new OperationError("ticket_expired", 401, true);
    const proof = setup.proof;
    if (!proof || proof.requestId !== setup.requestId || Math.abs(now - proof.issuedAt) >= 60) throw new OperationError("invalid_device_proof", 403);
    const parsed = request === undefined ? undefined : parseInput(accountRequest, request);
    if (parsed && parsed.requestId !== setup.requestId) throw new OperationError("invalid_device_proof", 403);
    const { proof: ignored, ...plainSetup } = setup;
    const body = parsed === undefined ? plainSetup : { setup: plainSetup, request: parsed };
    await verifyDeviceSignature(setup.device.endpointId, accountRequestSigningInput(setup.device, proof.requestId, proof.issuedAt, body, proof.nonce), proof.signature);
    this.dependencies.store.consumeProof(installationKey(identity), proof.nonce, proof.issuedAt, this.dependencies.now());
    const session: AccountSession = {
      sessionId: crypto.randomUUID(), userId: authority.userId, identity, endpointId: setup.device.endpointId,
      identityGeneration: setup.device.identityGeneration, expiresAt,
    };
    return { session, ...(parsed ? { request: parsed } : {}) };
  }

  /** A socket is admitted only for a Mac its team currently holds as an account peer. */
  async requireRequester(session: AccountSession): Promise<AccountMacRecord> {
    // Inside `consistent`: a revocation notice that lands while the team is
    // consulted forces a re-read, and the caller accepts the socket in the same
    // synchronous turn, after which later notices can find it by tag.
    const result = await this.consistent(async () => {
      const [record] = await this.records(session.identity.teamId, [session.identity]);
      return assertEligible(record ?? null, session);
    });
    this.assertLive(session);
    return result;
  }

  async execute(session: AccountSession, input: unknown): Promise<AccountResult> {
    const request = parseInput(accountRequest, input);
    this.assertLive(session);
    switch (request.schemaId) {
      case "account.publish.v1": return this.publish(session, request.requestId);
      case "account.directory.v1": return this.directory(session, request);
      case "account.withdraw.v1": {
        // Withdrawal needs only the ticket and proof, so a Mac its team revoked
        // can still take itself out of its other Macs' lists.
        const result = this.dependencies.store.withdraw(installationKey(session.identity), session.endpointId);
        return { response: { schemaId: "account.withdrawn.v1", requestId: request.requestId, revision: result.revision }, ...(result.changed ? { changed: result.revision } : {}) };
      }
    }
  }

  /**
   * TeamControl reports a change to one of this user's Mac records. Rows are
   * matched by record id or by installation, since a rekeyed record can carry
   * a new id.
   *
   * The notice counter moves first, before any await, so a publish or
   * directory read that consulted the team earlier retries instead of
   * committing or returning what it read. Notices themselves run one at a
   * time, so they never disturb each other and a burst cannot exhaust a
   * retry budget. A delete decided here is not version-checked: it removes
   * the row as long as it still names the same team, endpoint and generation
   * the team just refused, so a concurrent update cannot make a revocation miss.
   * That direction fails closed; a Mac that is valid again simply republishes.
   */
  teamChanged(teamId: string, deviceRecordId: string, identity: Identity): Promise<number | null> {
    this.notices++;
    const run = this.noticeTail.then(() => this.applyNotice(teamId, deviceRecordId, identity));
    this.noticeTail = run.then(() => undefined, () => undefined);
    return run;
  }

  private async applyNotice(teamId: string, deviceRecordId: string, identity: Identity): Promise<number | null> {
    const rows = this.dependencies.store.rowsForTeamDevice(teamId, deviceRecordId, installationKey(identity));
    if (rows.length === 0) return null;
    const records = await this.records(teamId, rows.map(row => row.device.descriptor.identity));
    const changes = rows.flatMap((row, index) => this.revalidation(row, records[index] ?? null) ?? []);
    const result = this.dependencies.store.revalidate(changes, this.dependencies.now(), "matching");
    return result.changed ? result.revision : null;
  }

  /** Why a socket's Mac may no longer use the account directory, or null while it still may. */
  async socketRevocation(session: AccountSession): Promise<OperationError | null> {
    const [record] = await this.records(session.identity.teamId, [session.identity]);
    try { assertEligible(record ?? null, session); return null; }
    catch (error) { return error instanceof OperationError ? error : new OperationError("device_revoked", 403); }
  }

  /**
   * Team records are read across an await. A revocation notice or another
   * account write landing meanwhile means what was read may predate the
   * revocation, so the read is retried; a persistently busy object answers
   * resync_required rather than commit or report a stale record as current.
   */
  private async consistent<T>(read: () => Promise<T>): Promise<T> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const before = this.snapshot();
      const value = await read();
      if (this.snapshot() === before) return value;
    }
    throw new OperationError("resync_required", 409, true, 250);
  }

  /** Moves on every notice and every account write, including writes that leave the revision alone. */
  private snapshot(): string { return this.notices + ":" + this.dependencies.store.fingerprint(); }

  private async publish(session: AccountSession, requestId: string): Promise<AccountResult> {
    // The upsert below runs in the same synchronous turn as the consistency check.
    const record = await this.consistent(async () => {
      const [found] = await this.records(session.identity.teamId, [session.identity]);
      return assertEligible(found ?? null, session);
    });
    if (recordBytes(record.device) > ACCOUNT_RECORD_BYTES) throw new OperationError("payload_too_large", 413);
    this.assertLive(session);
    const before = this.dependencies.store.readRevision();
    // Metadata always comes from the team record, never from the caller.
    const revision = this.dependencies.store.upsert({
      installationKey: installationKey(session.identity), teamId: session.identity.teamId, identityKey: identityKey(session.identity),
      device: record.device, authorityExpiresAt: record.authorityExpiresAt ?? 0, now: this.dependencies.now(),
    });
    return {
      response: { schemaId: "account.published.v1", requestId, revision, device: record.device },
      ...(revision !== before ? { changed: revision } : {}),
    };
  }

  private async directory(session: AccountSession, request: { requestId: string; cursor?: string | undefined; haveRevision?: number | undefined }): Promise<AccountResult> {
    const { byTeam, groups } = await this.consistent(async () => {
      const groups = new Map<string, { identities: Identity[]; rows: AccountMacRow[] }>();
      const group = (teamId: string) => {
        let value = groups.get(teamId);
        if (!value) { value = { identities: [], rows: [] }; groups.set(teamId, value); }
        return value;
      };
      group(session.identity.teamId).identities.push(session.identity);
      for (const row of this.dependencies.store.list()) {
        const entry = group(row.teamId);
        entry.identities.push(row.device.descriptor.identity);
        entry.rows.push(row);
      }
      const fetched = await Promise.all([...groups.entries()].map(async ([teamId, entry]) => [teamId, await this.records(teamId, entry.identities)] as const));
      return { byTeam: new Map(fetched), groups };
    });
    // Everything below is synchronous: no notice or account write can interleave.
    const requester = assertEligible(byTeam.get(session.identity.teamId)![0] ?? null, session);
    const changes: AccountRevalidation[] = [];
    const current: { row: AccountMacRow; record: AccountMacRecord }[] = [];
    for (const [teamId, entry] of groups) {
      const records = byTeam.get(teamId)!;
      const offset = teamId === session.identity.teamId ? 1 : 0;
      entry.rows.forEach((row, index) => {
        const record = records[index + offset] ?? null;
        const change = this.revalidation(row, record);
        if (change) changes.push(change);
        if (change?.kind !== "delete" && record !== null) current.push({ row, record });
      });
    }
    const now = this.dependencies.now();
    const { revision, changed } = this.dependencies.store.revalidate(changes, now);
    // The revalidation above is already committed; a stale cursor still has to
    // carry its revision so the adapter tells the other sockets.
    if (request.cursor !== undefined && request.haveRevision !== revision) throw new AccountResyncError(changed ? revision : undefined);
    const self = installationKey(session.identity);
    const requesterDescriptor = requester.device.descriptor;
    const namespace = requesterDescriptor.identity.appNamespace;
    const hosts = requesterDescriptor.metadata.capabilities.includes(MAC_HOST_CAPABILITY);
    const ordered = current
      .filter(({ record }) => request.cursor === undefined || record.device.deviceRecordId > request.cursor)
      .sort((left, right) => left.record.device.deviceRecordId < right.record.device.deviceRecordId ? -1 : 1);
    const macs: DeviceRecord[] = [];
    const inboundMacs: { device: DeviceRecord; permissionExpiresAt: number }[] = [];
    const directory: AccountDirectory = {
      userId: session.userId, revision, macs, inboundMacs, relayURLs: [...this.dependencies.relayURLs],
      issuedAt: now, permissionExpiresAt: Math.min(session.expiresAt, now + API_TICKET_SECONDS), rules: [...ACCOUNT_DIRECTORY_RULES],
      nextCursor: null,
    };
    let bytes = new TextEncoder().encode(JSON.stringify({ schemaId: "account.directory.result.v1", requestId: request.requestId, directory })).byteLength;
    let lastRecordId: string | null = null;
    for (const { row, record } of ordered) {
      const descriptor = record.device.descriptor;
      const listed = row.installationKey !== self && descriptor.identity.appNamespace === namespace
        && descriptor.metadata.capabilities.includes(MAC_HOST_CAPABILITY);
      // Same predicates as the team directory's Mac inbound rule, without the
      // team: opted-in host, same user (this object), namespace and build,
      // another endpoint, and an unexpired authority lease in the peer's team.
      const admitted = hosts && descriptor.identity.appNamespace === namespace && descriptor.identity.buildTag === requesterDescriptor.identity.buildTag
        && descriptor.endpointId !== requesterDescriptor.endpointId && descriptor.metadata.capabilities.includes(MAC_DEVICES_CAPABILITY)
        && record.authorityExpiresAt !== null && record.authorityExpiresAt > now;
      if (!listed && !admitted) continue;
      const inbound = admitted ? {
        device: record.device,
        permissionExpiresAt: Math.min(session.expiresAt, record.authorityExpiresAt!, now + ACCOUNT_INBOUND_GRANT_SECONDS),
      } : null;
      const size = (listed ? recordBytes(record.device) + 1 : 0) + (inbound ? new TextEncoder().encode(JSON.stringify(inbound)).byteLength + 1 : 0);
      if (bytes + size > ACCOUNT_PAGE_BYTES) {
        // Never publish a complete-looking page that silently omits a Mac.
        if (lastRecordId === null) throw new OperationError("payload_too_large", 413);
        directory.nextCursor = lastRecordId;
        break;
      }
      if (listed) macs.push(record.device);
      if (inbound) inboundMacs.push(inbound);
      lastRecordId = record.device.deviceRecordId;
      bytes += size;
    }
    this.assertLive(session);
    return { response: { schemaId: "account.directory.result.v1", requestId: request.requestId, directory }, ...(changed ? { changed: revision } : {}) };
  }

  /** The write that brings a row in line with its team record, or null when it already matches. */
  private revalidation(row: AccountMacRow, record: AccountMacRecord | null): AccountRevalidation | null {
    if (!eligible(record, row.device.descriptor) || record.device.descriptor.identity.userId !== this.dependencies.userId
      || recordBytes(record.device) > ACCOUNT_RECORD_BYTES) {
      return { kind: "delete", installationKey: row.installationKey, rowVersion: row.rowVersion, teamId: row.teamId,
        endpointId: row.device.descriptor.endpointId, identityGeneration: row.device.descriptor.identityGeneration };
    }
    const visible = JSON.stringify(record.device) !== JSON.stringify(row.device);
    const authorityExpiresAt = record.authorityExpiresAt ?? 0;
    if (!visible && authorityExpiresAt === row.authorityExpiresAt) return null;
    return { kind: "update", installationKey: row.installationKey, rowVersion: row.rowVersion, device: record.device, authorityExpiresAt, visible };
  }

  private async records(teamId: string, identities: Identity[]): Promise<(AccountMacRecord | null)[]> {
    let records: (AccountMacRecord | null)[];
    try { records = await this.dependencies.teamRecords(teamId, identities); }
    catch { throw new OperationError("upstream_unavailable", 503, true, 2000); }
    if (records.length !== identities.length) throw new OperationError("upstream_unavailable", 503, true, 2000);
    return records;
  }

  private assertLive(session: AccountSession): void {
    if (session.expiresAt <= this.dependencies.now()) throw new OperationError("ticket_expired", 401, true);
  }
}
