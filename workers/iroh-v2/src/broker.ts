import type { VerifiedAuthority } from "./auth";
import { encodeResponse, inputOperation, parseControlRequest } from "./boundary";
import type { DeviceDescriptor, DeviceRecord, Identity } from "./contracts/common";
import type { ControlRequest, SocketSetup } from "./contracts/requests";
import type { ControlResponse } from "./contracts/responses";
import type { DashboardClaims } from "./dashboard-auth";
import { API_TICKET_SECONDS, CHALLENGE_SECONDS, canonicalJSON, challengeSigningInput, encodeBase64URL, hash, requestSigningInput, verifyDeviceSignature } from "./crypto";
import { OperationError } from "./errors";
import type { EndpointOwnership } from "./ownership/planetscale";
import type { RelayIssuer } from "./relay";
import type { TeamStore } from "./storage/team-store";
import type { WorkspaceProductStore } from "./workspaces/productStore";

export interface BrokerSession {
  readonly sessionId: string;
  readonly identity: Identity;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly authority: VerifiedAuthority;
  readonly expiresAt: number;
}

export interface BrokerDependencies {
  readonly store: TeamStore;
  readonly ownership: EndpointOwnership;
  readonly relays: RelayIssuer;
  readonly now: () => number;
  readonly charge: (userId: string, operation: string) => Promise<void>;
  readonly issueTicket: (device: DeviceDescriptor, now: number) => Promise<{ token: string; expiresAt: number; refreshAfter: number }>;
  readonly verifyStack: (token: string, identity: Identity, now: number) => Promise<VerifiedAuthority>;
  readonly canManageTeam: (authority: VerifiedAuthority) => Promise<boolean>;
  readonly verifyTeamMember: (teamId: string, userId: string) => Promise<boolean>;
  readonly workspace?: WorkspaceProductStore;
}

export interface BrokerResult {
  readonly response: ControlResponse;
  readonly session?: BrokerSession;
  readonly changed?: { revision: number; revokedDeviceRecordId?: string; permissionUserId?: string };
  readonly close?: boolean;
  readonly workspaceChanged?: { vmId: string; generation: string; revision: number };
}

/** HTTP and socket adapters use this same authority and storage path. */
export class TeamBroker {
  constructor(readonly dependencies: BrokerDependencies) {}

  /** Auth has been verified by the Worker, including selected team membership. */
  async open(setup: SocketSetup, authority: VerifiedAuthority, expiresAt: number, issueTicket: boolean): Promise<BrokerResult> {
    this.assertAuthority(authority, setup.device.identity);
    const now = this.dependencies.now();
    if (expiresAt <= now) throw new OperationError("ticket_expired", 401, true);
    if (setup.device.metadata.platform === "mac" && !setup.device.metadata.pairingEnabled) throw new OperationError("permission_denied", 403);
    let existing = this.dependencies.store.getDevice(setup.device.identity);
    if (existing) {
      this.assertDevice(existing, setup.device);
      if (!setup.proof) throw new OperationError("invalid_device_proof", 403);
    }
    if (setup.proof) {
      if (setup.proof.requestId !== setup.requestId || Math.abs(now - setup.proof.issuedAt) >= 60) throw new OperationError("invalid_device_proof", 403);
      const { proof, ...body } = setup;
      await verifyDeviceSignature(setup.device.endpointId, requestSigningInput(setup.device, proof.requestId, proof.issuedAt, body, proof.nonce), proof.signature);
    }
    existing = this.dependencies.store.getDevice(setup.device.identity);
    if (existing) {
      this.assertDevice(existing, setup.device);
      if (!setup.proof) throw new OperationError("invalid_device_proof", 403);
      this.dependencies.store.consumeDeviceProof({ ...setup.device, requestId: setup.proof.nonce, issuedAt: setup.proof.issuedAt, now: this.dependencies.now() });
    }
    const session: BrokerSession = {
      sessionId: crypto.randomUUID(), identity: setup.device.identity, endpointId: setup.device.endpointId,
      identityGeneration: setup.device.identityGeneration, authority, expiresAt,
    };
    let ticket;
    if (issueTicket) {
      await this.dependencies.charge(authority.userId, "ticket.request");
      ticket = await this.dependencies.issueTicket(setup.device, authority.verifiedAt);
    }
    const challenge = existing ? undefined : await this.challenge(session, setup.device);
    // Signing and user-budget calls can yield to revocation or key replacement.
    existing = this.dependencies.store.getDevice(setup.device.identity);
    if (existing) this.assertDevice(existing, setup.device);
    if (session.expiresAt <= this.dependencies.now()) throw new OperationError("ticket_expired", 401, true);
    const revision = this.observeAuthority(authority);
    return {
      session,
      ...(revision === null ? {} : { changed: { revision } }),
      response: {
        schemaId: "session.ready.v1", requestId: setup.requestId, sessionId: session.sessionId,
        teamRevision: this.dependencies.store.readRevision(),
        ...(ticket ? { ticket } : {}), ...(challenge ? { challenge } : {}), ...(existing ? { device: existing } : {}),
      },
    };
  }

  /** HTTP authorization proves this exact operation before using the local broker. */
  async authorizeHTTP(setup: SocketSetup, input: unknown, authority: VerifiedAuthority, expiresAt: number): Promise<BrokerSession> {
    this.assertAuthority(authority, setup.device.identity);
    const now = this.dependencies.now();
    const request = parseControlRequest(input);
    const proof = setup.proof;
    if (!proof || proof.requestId !== setup.requestId || request.requestId !== setup.requestId || Math.abs(now - proof.issuedAt) >= 60) {
      throw new OperationError("invalid_device_proof", 403);
    }
    const { proof: ignored, ...plainSetup } = setup;
    await verifyDeviceSignature(setup.device.endpointId, requestSigningInput(setup.device, proof.requestId, proof.issuedAt, { setup: plainSetup, request }, proof.nonce), proof.signature);
    const existing = this.dependencies.store.getDevice(setup.device.identity);
    if (existing) {
      this.assertDevice(existing, setup.device);
      this.dependencies.store.consumeDeviceProof({ ...setup.device, requestId: proof.nonce, issuedAt: proof.issuedAt, now: this.dependencies.now() });
    } else if (request.schemaId !== "challenge.request.v1" && request.schemaId !== "device.register.v1") {
      throw new OperationError("device_not_enrolled", 409);
    }
    return { sessionId: proof.requestId, identity: setup.device.identity, endpointId: setup.device.endpointId, identityGeneration: setup.device.identityGeneration, authority, expiresAt };
  }

  async execute(session: BrokerSession, input: unknown): Promise<BrokerResult> {
    const operation = inputOperation(input);
    await this.dependencies.charge(session.identity.userId, operation);
    const request = parseControlRequest(input);
    this.assertAuthority(session.authority, session.identity);
    const now = this.dependencies.now();
    if (session.expiresAt <= now && request.schemaId !== "ticket.request.v1" && request.schemaId !== "session.goodbye.v1") {
      throw new OperationError("ticket_expired", 401, true);
    }
    const existing = this.dependencies.store.getDevice(session.identity);
    if (existing) this.assertDevice(existing, session);
    if (!existing && request.schemaId !== "device.register.v1" && request.schemaId !== "challenge.request.v1" && request.schemaId !== "session.goodbye.v1") {
      throw new OperationError("device_not_enrolled", 409);
    }
    // Reusing a ticket observes its original verification time and never extends it.
    const revision = session.expiresAt > now ? this.observeAuthority(session.authority) : null;
    const result = await this.executeRequest(session, request, now);
    return revision === null ? result : { ...result, changed: { revision, ...result.changed } };
  }

  /** Browser control uses the same team store and user operation limits, without enrollment. */
  async executeDashboard(session: DashboardClaims, input: unknown): Promise<BrokerResult> {
    await this.dependencies.charge(session.authority.userId, inputOperation(input));
    const request = parseControlRequest(input);
    const now = this.dependencies.now();
    const authority = session.authority;
    if (session.expiresAt <= now) throw new OperationError("ticket_expired", 401, true);
    switch (request.schemaId) {
      case "directory.request.v1": {
        const revision = this.dependencies.store.readRevision();
        if (request.cursor && request.haveRevision !== revision) throw new OperationError("resync_required", 409, true);
        const records = this.dependencies.store.listDashboardDevices(authority.userId, session.canManageTeam, request.cursor);
        const devices: DeviceRecord[] = [], managedDeviceIds: string[] = [];
        const directory = { teamId: authority.teamId, revision, devices, managedDeviceIds,
          canManageTeam: session.canManageTeam, relayURLs: this.relayURLs(), issuedAt: now, nextCursor: null as string | null };
        const response = { schemaId: "dashboard.directory.v1" as const, requestId: request.requestId, directory };
        let bytes = new TextEncoder().encode(JSON.stringify(response)).byteLength;
        let lastRecordId: string | null = null;
        for (const record of records) {
          const size = new TextEncoder().encode(JSON.stringify(record.device)).byteLength + (record.canManage ? record.device.deviceRecordId.length + 3 : 0) + 1;
          if (bytes + size > 60 * 1024) {
            if (lastRecordId === null) throw new OperationError("payload_too_large", 413);
            directory.nextCursor = lastRecordId; break;
          }
          devices.push(record.device);
          if (record.canManage) managedDeviceIds.push(record.device.deviceRecordId);
          lastRecordId = record.device.deviceRecordId; bytes += size;
        }
        if (records.length === 1024 && lastRecordId === records.at(-1)!.device.deviceRecordId) directory.nextCursor = lastRecordId;
        encodeResponse(response);
        return { response };
      }
      case "device.revoke.v1": {
        let target = this.dependencies.store.getDeviceByRecordId(request.deviceRecordId);
        if (!target) throw new OperationError("permission_denied", 403);
        const locallyAllowed = () => target!.descriptor.identity.userId === authority.userId
          || this.dependencies.store.getPermission(authority.userId, request.deviceRecordId)?.manage === true;
        if (!locallyAllowed() && !await this.dependencies.canManageTeam(authority)) throw new OperationError("permission_denied", 403);
        if (session.expiresAt <= this.dependencies.now()) throw new OperationError("ticket_expired", 401, true);
        target = this.dependencies.store.getDeviceByRecordId(request.deviceRecordId);
        if (!target) throw new OperationError("permission_denied", 403);
        if (target.revoked) return this.completed(request.requestId, target.revision);
        const revision = this.dependencies.store.revokeDevice(target.deviceRecordId, this.dependencies.now(), authority.userId);
        return { ...this.completed(request.requestId, revision), changed: { revision, revokedDeviceRecordId: target.deviceRecordId } };
      }
      case "preferences.update.v1": {
        if (!await this.dependencies.canManageTeam(authority)) throw new OperationError("permission_denied", 403);
        if (session.expiresAt <= this.dependencies.now()) throw new OperationError("ticket_expired", 401, true);
        if (request.relayURLs.some(url => !this.dependencies.relays.configuration.relayURLs.includes(url))) throw new OperationError("invalid_request", 400);
        const revision = this.dependencies.store.updateRelayPreferences(request.relayURLs, request.expectedRevision, authority.userId, this.dependencies.now());
        return { ...this.completed(request.requestId, revision), changed: { revision } };
      }
      case "workspace.get.v1": {
        if (!this.dependencies.workspace) throw new OperationError("upstream_unavailable", 503, true, 2000);
        const current = await this.dependencies.workspace.get(authority.teamId, request.vmId);
        if (!current) throw new OperationError("resync_required", 409, true);
        return { response: { schemaId: "workspace.snapshot.result.v1", requestId: request.requestId, vmId: request.vmId, ...current } };
      }
      case "session.goodbye.v1": return { ...this.completed(request.requestId, this.dependencies.store.readRevision()), close: true };
      default: throw new OperationError("unsupported_method", 400);
    }
  }

  private async executeRequest(session: BrokerSession, request: ControlRequest, now: number): Promise<BrokerResult> {
    switch (request.schemaId) {
      case "challenge.request.v1": {
        this.assertSessionDevice(session, request.device);
        // execute already charged this logical operation; setup charges separately.
        const challenge = await this.challenge(session, request.device, false);
        return { response: { schemaId: "challenge.result.v1", requestId: request.requestId, challenge } };
      }
      case "device.register.v1": return this.register(session, request);
      case "ticket.request.v1": {
        const authority = await this.dependencies.verifyStack(request.stackAccessToken, session.identity, now);
        this.assertAuthority(authority, session.identity);
        // Re-read after remote auth; revocation wins over a concurrent renewal.
        const record = this.requiredDevice(session);
        const ticket = await this.dependencies.issueTicket(record.descriptor, authority.verifiedAt);
        this.requiredDevice(session);
        const revision = this.observeAuthority(authority);
        return {
          response: { schemaId: "ticket.result.v1", requestId: request.requestId, ticket },
          session: { ...session, authority, expiresAt: ticket.expiresAt },
          ...(revision === null ? {} : { changed: { revision } }),
        };
      }
      case "relay.request.v1": {
        const record = this.requiredDevice(session);
        const credentials = await this.dependencies.relays.issue(record.descriptor, now, this.relayURLs());
        this.requiredDevice(session);
        return { response: { schemaId: "relay.result.v1", requestId: request.requestId, credentials } };
      }
      case "directory.request.v1": return { response: this.directory(session, request, now) };
      case "device.metadata.v1": {
        const record = this.requiredDevice(session);
        if (request.metadata.platform !== record.descriptor.metadata.platform) throw new OperationError("identity_mismatch", 409);
        if (canonicalJSON(record.descriptor.metadata) === canonicalJSON(request.metadata)) return this.completed(request.requestId, record.revision);
        const changed = this.dependencies.store.updateMetadata(session.identity, request.metadata, now);
        return { ...this.completed(request.requestId, changed.revision), changed: { revision: changed.revision } };
      }
      case "device.revoke.v1": {
        const target = this.manageableDevice(session, request.deviceRecordId);
        if (target.revoked) return this.completed(request.requestId, target.revision);
        const revision = this.dependencies.store.revokeDevice(request.deviceRecordId, now, session.identity.userId);
        return { ...this.completed(request.requestId, revision), changed: { revision, revokedDeviceRecordId: request.deviceRecordId } };
      }
      case "permission.update.v1": {
        this.manageableDevice(session, request.permission.deviceRecordId);
        if (!await this.dependencies.verifyTeamMember(session.identity.teamId, request.permission.subjectUserId)) throw new OperationError("permission_denied", 403);
        this.requiredDevice(session);
        this.manageableDevice(session, request.permission.deviceRecordId);
        const current = this.dependencies.store.getPermission(request.permission.subjectUserId, request.permission.deviceRecordId);
        if (current && canonicalJSON(current) === canonicalJSON(request.permission)) return this.completed(request.requestId, this.dependencies.store.readRevision());
        const revision = this.dependencies.store.setPermission(request.permission, now, session.identity.userId);
        return { ...this.completed(request.requestId, revision), changed: { revision, permissionUserId: request.permission.subjectUserId } };
      }
      case "preferences.update.v1": {
        if (!await this.dependencies.canManageTeam(session.authority)) throw new OperationError("permission_denied", 403);
        this.requiredDevice(session);
        if (request.relayURLs.some(url => !this.dependencies.relays.configuration.relayURLs.includes(url))) throw new OperationError("invalid_request", 400);
        const revision = this.dependencies.store.updateRelayPreferences(request.relayURLs, request.expectedRevision, session.identity.userId, now);
        return { ...this.completed(request.requestId, revision), changed: { revision } };
      }
      case "session.goodbye.v1": return { ...this.completed(request.requestId, this.dependencies.store.readRevision()), close: true };
      case "workspace.snapshot.v1": {
        if (!this.dependencies.workspace) throw new OperationError("upstream_unavailable", 503, true, 2000);
        this.requiredDevice(session);
        if (request.vmId !== session.identity.deviceId) throw new OperationError("permission_denied", 403);
        if (request.generation !== String(session.identityGeneration)) throw new OperationError("identity_mismatch", 403);
        const write = await this.dependencies.workspace.put({ teamId: session.identity.teamId, vmId: request.vmId, generation: request.generation, revision: request.revision, snapshot: request.snapshot });
        return {
          ...this.completed(request.requestId, this.dependencies.store.readRevision()),
          response: { schemaId: "workspace.snapshot.result.v1", requestId: request.requestId, vmId: request.vmId, ...write.state },
          ...(write.changed ? { workspaceChanged: { vmId: request.vmId, generation: write.state.generation, revision: write.state.revision } } : {}),
        };
      }
      case "workspace.get.v1": {
        if (!this.dependencies.workspace) throw new OperationError("upstream_unavailable", 503, true, 2000);
        this.requiredDevice(session);
        const current = await this.dependencies.workspace.get(session.identity.teamId, request.vmId);
        if (!current) throw new OperationError("resync_required", 409, true);
        return { response: { schemaId: "workspace.snapshot.result.v1", requestId: request.requestId, vmId: request.vmId, ...current } };
      }
      case "session.ack.v1": throw new OperationError("unsupported_method", 400); // Socket adapter owns its delivery ledger.
    }
  }

  requiredDevice(session: BrokerSession): DeviceRecord {
    const record = this.dependencies.store.getDevice(session.identity);
    if (!record) throw new OperationError("device_not_enrolled", 409);
    this.assertDevice(record, session);
    return record;
  }

  private async challenge(session: BrokerSession, device: DeviceDescriptor, charge = true) {
    this.assertSessionDevice(session, device);
    const existing = this.dependencies.store.getDevice(device.identity);
    if (existing) this.assertDevice(existing, device);
    if (charge) await this.dependencies.charge(session.identity.userId, "challenge.request");
    const now = this.dependencies.now();
    const challengeId = crypto.randomUUID();
    const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(32)));
    const payloadHash = await hash(canonicalJSON(device));
    const nonceHash = await hash(nonce);
    const expiresAt = now + CHALLENGE_SECONDS;
    const current = this.dependencies.store.getDevice(device.identity);
    if (current) this.assertDevice(current, device);
    if (session.expiresAt <= this.dependencies.now()) throw new OperationError("ticket_expired", 401, true);
    this.dependencies.store.issueChallenge(device.identity, { challengeId, nonceHash, payloadHash, expiresAt, issuedAt: now });
    return { challengeId, nonce, payloadHash, expiresAt };
  }

  private async register(session: BrokerSession, request: Extract<ControlRequest, { schemaId: "device.register.v1" }>): Promise<BrokerResult> {
    this.assertSessionDevice(session, request.device);
    if (request.device.metadata.platform === "mac" && !request.device.metadata.pairingEnabled) throw new OperationError("permission_denied", 403);
    await verifyDeviceSignature(request.device.endpointId, challengeSigningInput(request.device, request.challengeId, request.nonce), request.signature);
    const commit = {
      descriptor: request.device, challengeId: request.challengeId, nonceHash: await hash(request.nonce),
      payloadHash: await hash(canonicalJSON(request.device)), requestId: request.requestId,
      requestHash: await hash(canonicalJSON(request)), now: this.dependencies.now(),
    };
    const receipt = this.dependencies.store.findRegistrationReceipt(session.identity, request.requestId, commit.requestHash);
    if (receipt) return { response: { schemaId: "device.registered.v1", requestId: request.requestId, device: receipt.device } };
    this.dependencies.store.validateRegistrationChallenge(commit);
    await this.dependencies.ownership.reserve(request.device, commit.now);
    const result = this.dependencies.store.commitRegistration({ ...commit, now: this.dependencies.now() });
    return {
      response: { schemaId: "device.registered.v1", requestId: request.requestId, device: result.device },
      ...(result.idempotent ? {} : { changed: { revision: result.device.revision } }),
    };
  }

  private directory(session: BrokerSession, request: Extract<ControlRequest, { schemaId: "directory.request.v1" }>, now: number): ControlResponse {
    const revision = this.dependencies.store.readRevision();
    if (request.cursor && request.haveRevision !== revision) throw new OperationError("resync_required", 409, true);
    const requester = this.requiredDevice(session);
    const records = this.dependencies.store.listDirectoryDevices(requester, now, request.cursor, 1024);
    const devices: DeviceRecord[] = [];
    const inboundPeers: { device: DeviceRecord; permissionExpiresAt: number }[] = [];
    const response = {
      schemaId: "directory.result.v1" as const, requestId: request.requestId,
      directory: {
        teamId: session.identity.teamId, revision, devices, inboundPeers, relayURLs: this.relayURLs(),
        issuedAt: now, permissionExpiresAt: Math.min(session.expiresAt, now + API_TICKET_SECONDS), nextCursor: null as string | null,
      },
    };
    let bytes = new TextEncoder().encode(JSON.stringify(response)).byteLength;
    let lastRecordId: string | null = null;
    for (const record of records) {
      const inbound = record.inboundPermissionExpiresAt === null ? null : {
        device: record.device, permissionExpiresAt: Math.min(session.expiresAt, record.inboundPermissionExpiresAt),
      };
      const size = (record.visible ? new TextEncoder().encode(JSON.stringify(record.device)).byteLength + 1 : 0)
        + (inbound ? new TextEncoder().encode(JSON.stringify(inbound)).byteLength + 1 : 0);
      if (bytes + size > 60 * 1024) {
        // Never publish a complete-looking empty page when one row cannot fit.
        if (lastRecordId === null) throw new OperationError("payload_too_large", 413);
        response.directory.nextCursor = lastRecordId; break;
      }
      if (record.visible) devices.push(record.device);
      if (inbound) inboundPeers.push(inbound);
      lastRecordId = record.device.deviceRecordId;
      bytes += size;
    }
    if (records.length === 1024 && lastRecordId === records.at(-1)!.device.deviceRecordId) response.directory.nextCursor = lastRecordId;
    encodeResponse(response);
    return response;
  }

  private manageableDevice(session: BrokerSession, deviceRecordId: string): DeviceRecord {
    const record = this.dependencies.store.getDeviceByRecordId(deviceRecordId);
    if (!record) throw new OperationError("permission_denied", 403);
    const permission = this.dependencies.store.getPermission(session.identity.userId, deviceRecordId);
    if (record.descriptor.identity.userId !== session.identity.userId && !permission?.manage) throw new OperationError("permission_denied", 403);
    return record;
  }

  private relayURLs(): string[] {
    const configured = this.dependencies.relays.configuration.relayURLs;
    const configuredSet = new Set(configured);
    // Team preferences can outlive a relay rollout. Only advertise relays that
    // are currently configured for this worker; falling back to the complete
    // configured set keeps an old preference from producing unusable tickets.
    const preference = this.dependencies.store.getRelayPreferences().relayURLs.filter(url => configuredSet.has(url));
    return preference.length ? preference : configured;
  }

  private completed(requestId: string, revision: number): BrokerResult {
    return { response: { schemaId: "operation.completed.v1", requestId, revision } };
  }

  private observeAuthority(authority: VerifiedAuthority): number | null {
    return this.dependencies.store.observeAuthority(authority.userId, authority.verifiedAt, authority.verifiedAt + API_TICKET_SECONDS, this.dependencies.now());
  }

  private assertAuthority(authority: VerifiedAuthority, identity: Identity): void {
    if (authority.environment !== identity.environment || authority.projectId !== identity.projectId || authority.teamId !== identity.teamId || authority.userId !== identity.userId) {
      throw new OperationError("identity_mismatch", 403);
    }
  }

  private assertSessionDevice(session: BrokerSession, device: DeviceDescriptor): void {
    if (canonicalJSON(session.identity) !== canonicalJSON(device.identity) || session.endpointId !== device.endpointId || session.identityGeneration !== device.identityGeneration) {
      throw new OperationError("identity_mismatch", 403);
    }
  }

  private assertDevice(record: DeviceRecord, device: { endpointId: string; identityGeneration: number }): void {
    if (record.revoked) throw new OperationError("device_revoked", 403);
    if (record.descriptor.endpointId !== device.endpointId || record.descriptor.identityGeneration !== device.identityGeneration) throw new OperationError("key_replacement_required", 409);
  }
}
