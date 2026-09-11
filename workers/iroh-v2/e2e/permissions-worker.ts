import { TeamBroker, type BrokerSession } from "../src/broker";
import { encodeResponse } from "../src/boundary";
import type { DeviceRecord } from "../src/contracts/common";
import { OperationError } from "../src/errors";
import type { RelayIssuer } from "../src/relay";
import { TeamStore } from "../src/storage/team-store";

const scope = { environment: "test", projectId: "permissions", teamId: "team" };

/** Fixtures supply verified sessions; the production broker and SQLite decide access. */
export class PermissionTestDO {
  private readonly store: TeamStore;
  private readonly devices = new Map<string, DeviceRecord>();
  private readonly broker: TeamBroker;
  private now = 1200;
  private stackCalls = 0;

  constructor(ctx: DurableObjectState) {
    this.store = new TeamStore(ctx.storage, scope, { initialize: false });
    ctx.blockConcurrencyWhile(async () => {
      this.store.initialize();
      const seeds = [
        ["mac-alice", "alice", "mac"], ["mac-bob", "bob", "mac"],
        ["phone-alice", "alice", "ios"], ["phone-bob", "bob", "ios"], ["phone-eve", "eve", "ios"],
      ] as const;
      for (const [index, [name, userId, platform]] of seeds.entries()) {
        const descriptor = {
          identity: { ...scope, userId, deviceId: name, appNamespace: "cmux", buildTag: "test" },
          endpointId: (index + 1).toString(16).padStart(64, "0"), identityGeneration: 0,
          metadata: { platform, displayName: name, appVersion: "2", pairingEnabled: true, capabilities: [], relayURLs: [] },
        };
        const existing = this.store.getDevice(descriptor.identity);
        if (existing) { this.devices.set(name, existing); continue; }
        const challenge = { challengeId: name, nonceHash: name, payloadHash: name, issuedAt: 1000, expiresAt: 2800 };
        this.store.issueChallenge(descriptor.identity, challenge);
        const result = this.store.commitRegistration({ descriptor, ...challenge, requestId: name, requestHash: name, now: 1001 });
        this.devices.set(name, result.device);
      }
      for (const [user, time] of [["alice", 1200], ["bob", 1000], ["eve", 1000]] as const) this.store.observeAuthority(user, time, time + 3600, this.now);
      for (const [user, target] of [["alice", "mac-bob"], ["bob", "mac-alice"], ["eve", "mac-bob"]]) {
        this.store.setPermission({ subjectUserId: user!, deviceRecordId: this.devices.get(target!)!.deviceRecordId, connect: true, manage: false }, this.now, "fixture");
      }
    });
    this.broker = new TeamBroker({
      store: this.store, now: () => this.now, charge: async () => {},
      ownership: { reserve: async () => { throw new Error("Registration not exercised by this harness"); } },
      relays: { configuration: { relayURLs: ["https://relay.test"] } } as RelayIssuer,
      issueTicket: async (_, now) => ({ token: "test-only", expiresAt: now + 3600, refreshAfter: now + 3300 }),
      verifyStack: async (_, identity, now) => { this.stackCalls++; return { ...scope, userId: identity.userId, verifiedAt: now }; },
      canManageTeam: async () => false, verifyTeamMember: async () => true,
    });
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const input = await request.json() as any;
      const path = new URL(request.url).pathname;
      if (path === "/time") { this.now = input.now; return Response.json({ ok: true }); }
      if (path === "/authority") return Response.json({ authority: this.store.getAuthority(input.user), stackCalls: this.stackCalls });
      const device = this.devices.get(input.device ?? "mac-alice")!;
      if (path === "/permission") {
        this.store.setPermission({ subjectUserId: input.user, deviceRecordId: device.deviceRecordId, connect: input.connect, manage: false }, this.now, "fixture");
        return Response.json({ ok: true });
      }
      if (path === "/revoke") { this.store.revokeDevice(device.deviceRecordId, this.now, "fixture"); return Response.json({ ok: true }); }
      if (path === "/pairing") {
        this.store.updateMetadata(device.descriptor.identity, { ...device.descriptor.metadata, pairingEnabled: input.enabled }, this.now);
        return Response.json({ ok: true });
      }
      if (path === "/page") return Response.json(this.store.listDirectoryDevices(this.store.getDevice(device.descriptor.identity)!, this.now, input.cursor, input.limit));
      const verifiedAt = device.descriptor.identity.userId === "alice" ? 1200 : 1000;
      const session: BrokerSession = {
        sessionId: "fixture", identity: device.descriptor.identity, endpointId: device.descriptor.endpointId, identityGeneration: 0,
        authority: { ...scope, userId: device.descriptor.identity.userId, verifiedAt }, expiresAt: verifiedAt + 3600,
      };
      const message = path === "/renew" ? { schemaId: "ticket.request.v1", requestId: "renew", stackAccessToken: "fixture" }
        : { schemaId: "directory.request.v1", requestId: "directory", ...(input.cursor ? { cursor: input.cursor, haveRevision: input.revision } : {}) };
      const result = await this.broker.execute(session, message);
      return new Response(encodeResponse(result.response), { headers: { "content-type": "application/json" } });
    } catch (error) {
      return Response.json({ code: error instanceof Error ? error.message : "unknown" }, { status: error instanceof OperationError ? error.status : 500 });
    }
  }
}
export default { fetch: () => new Response("permission harness") };
