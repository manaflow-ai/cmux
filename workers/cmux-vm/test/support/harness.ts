/**
 * Test harness: the real API, handlers, middleware, proofs and session
 * verifier, with in-memory stores, a local JWKS, a fake team directory and a
 * fake upstream provider behind the real upstream client.
 */
import { Effect, Layer, Option, Redacted } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { makeWebHandler } from "../../src/app.ts";
import { generateApiKey, hashApiKey, makeStackSessionVerifier, makeStackTeamMembership, SessionVerifier, TeamMembership } from "../../src/auth/credentials.ts";
import { makeMemoryMembershipCache } from "../../src/auth/membership-cache.ts";
import { signWebhookContent } from "../../src/auth/webhook-signature.ts";
import { makeMemoryWebhookDeliveryStore } from "../../src/db/identity.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, type ApiKeyRecord, type OwnedResource } from "../../src/db/stores.ts";
import type { Scope } from "../../src/domain/scopes.ts";
import { newApiKeyId, newSnapshotId, newVmId, TenantId, UpstreamId, UserId, type SnapshotId, type VmId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer, type TenantLimits } from "../../src/limits/service.ts";
import { StoreError } from "../../src/db/sql.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { Entitlements } from "../../src/proofs/tenant-may-create.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";
import { makeUpstreamClient } from "../../src/upstream/live.ts";
import { parseVmImages, VmImages } from "../../src/upstream/live-images.ts";
import { makeFakeUpstream } from "./fake-upstream.ts";
import { makeS3aFakes } from "./s3a-fakes.ts";
import { TeamAdmin } from "../../src/auth/team-admin.ts";
import { ApiKeyAdminStore } from "../../src/db/api-keys.ts";
import { ServiceKeys } from "../../src/auth/service-keys.ts";
import { makeMeshFakes, type MeshFakeOptions } from "./mesh-fakes.ts";
import { AgentStore, type ClientSessionRow } from "../../src/db/agents.ts";

export const STACK_API_URL = "https://stack.test";
export const STACK_PROJECT_ID = "project-test";
const UPSTREAM_URL = "https://upstream.test";
const UPSTREAM_KEY = "upstream-test-key";

export interface HarnessOptions {
  readonly limits?: Layer.Layer<TenantLimits>;
  /** Operator-approved image configuration, as supplied to the Worker. */
  readonly bootImages?: string;
  readonly httpsProxyOrigins?: ReadonlyArray<string>;
  /** The deployment environment; every tenant is dev/test outside production. */
  readonly environment?: "local" | "staging" | "production";
  /** Tenants treated as dev/test in production. */
  readonly devTestTenants?: ReadonlyArray<string>;
  /** Live VMs per tenant. */
  readonly maxVms?: number;
  /** Live snapshots per tenant. */
  readonly maxSnapshots?: number;
  /** Requests per minute per tenant for each limit class. */
  readonly ratePerMinute?: Partial<Record<"read" | "write" | "exec" | "files", number>>;
  /** Largest file upload accepted, in bytes. */
  readonly maxUploadBytes?: number;
  /** Mesh experiment (cx-0op): flag, allowlisted tenants (default team_alpha and team_bravo) and budgets. */
  readonly mesh?: MeshFakeOptions;
  /** The Stack webhook signing secret (whsec_...); absent: the webhook answers 503. */
  readonly stackWebhookSecret?: string;
}

/** One audit row as a test sees it. */
export interface AuditRow {
  readonly tenantId: string;
  readonly actor: string;
  readonly action: string;
  readonly cmuxId: string | null;
  readonly outcome: string;
  /** The owner a device or system actor acted for (mesh M4); null otherwise. */
  readonly ownerActor: string | null;
}

type SigningKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];

interface StoredKey extends ApiKeyRecord {
  readonly hash: string;
  readonly revoked: boolean;
  readonly expiresAt: Date | null;
  /** Set by the API key management endpoints (cx-b4h.12). */
  readonly name?: string;
  readonly createdBy?: string;
  readonly createdAt?: Date;
  readonly revokedAt?: Date;
  /** Set when the reaper finished an agent key. */
  readonly cleanedAt?: Date;
}

export async function makeHarness(options: HarnessOptions = {}) {
  const resources: OwnedResource[] = [];
  const recordFault = { before: 0, after: 0 };
  const meshRecordFault = { before: 0, after: 0 };
  const keys: StoredKey[] = [];
  /** Service keys (cx-b4h.13), as parsed from the CMUX_VM_SERVICE_KEYS secret. */
  const serviceKeys: Array<{
    readonly id: string;
    readonly sha256: string;
    readonly scopes: ReadonlyArray<Scope>;
    readonly labels: Readonly<Record<string, string>>;
    readonly teams: ReadonlyArray<string> | null;
  }> = [];
  const members = new Map<string, Set<string>>();
  /** Stack server_metadata per team, as the server API returns it. */
  const stackMetadata = new Map<string, unknown>();
  /** Team admins (Stack team_admin), per tenant. */
  const admins = new Map<string, Set<string>>();
  const upstream = makeFakeUpstream(UPSTREAM_KEY);
  /** Client sessions (migration 0016), as cmux_vm.vm_client_sessions holds them. */
  const clientSessions: ClientSessionRow[] = [];
  const upstreamClient = makeUpstreamClient({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), environment: "local", fetch: (request) => upstream.fetch(request) });
  const upstreamRequests = upstream.calls;
  const audit: AuditRow[] = [];
  /** Tenants whose plan allows creating VMs. */
  const billed = new Set<string>(["team_alpha", "team_bravo"]);
  /** Public ids marked deleted; their rows stay in `resources` for inspection. */
  const deleted = new Set<string>();
  const live = (row: OwnedResource) => !deleted.has(row.cmuxId);
  /** Strictly increasing creation times, so "newest first" is deterministic within a millisecond. */
  let lastCreatedMs = 0;
  const nextCreatedAt = (at: Date) => {
    lastCreatedMs = Math.max(at.getTime(), lastCreatedMs + 1);
    return new Date(lastCreatedMs);
  };

  /** Stack server API calls that asked for a user's teams (membership lookups). */
  const stackMembershipCalls: string[] = [];
  /** Users Stack cannot answer for (a deleted user, or Stack down for them): their lookups answer 500. */
  const stackFailing = new Set<string>();
  const stackFetch = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname !== "/api/v1/teams") return Response.json({ message: "no route" }, { status: 404 });
    const user = url.searchParams.get("user_id") ?? "";
    stackMembershipCalls.push(user);
    if (stackFailing.has(user)) return Response.json({ message: "injected failure" }, { status: 500 });
    const items = [...members].filter(([, users]) => users.has(user)).map(([team]) => ({ id: team, server_metadata: stackMetadata.get(team) ?? null }));
    return Response.json({ items });
  };
  const membershipCache = makeMemoryMembershipCache();
  const webhookDeliveries = makeMemoryWebhookDeliveryStore();

  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "ES256" };
  const getKey = createLocalJWKSet({ keys: [jwk] });

  const ownership = Layer.succeed(OwnershipStore, {
    findCreation: (tenantId, key) => Effect.sync(() => {
      const row = [...resources].reverse().find((r) => r.tenantId === tenantId && r.kind === "vm" && r.creation?.key === key);
      return row?.creation === undefined ? null : { receipt: row.creation.receipt, labels: row.labels, createdBy: row.createdBy, deleted: deleted.has(row.cmuxId), committed: row.committed !== false };
    }),
    allocationStatus: (tenantId, cmuxId) => Effect.sync(() => {
      const row = resources.find((r) => r.tenantId === tenantId && r.kind === "vm" && r.cmuxId === cmuxId);
      return !row ? "absent" as const : deleted.has(cmuxId) ? "deleted" as const : row.committed === false ? "pending" as const : "live" as const;
    }),
    creationKey: (tenantId, cmuxId) => Effect.sync(() => {
      const row = resources.find((r) => r.tenantId === tenantId && r.kind === "vm" && r.cmuxId === cmuxId);
      return row?.creation?.key ?? null;
    }),
    find: (tenantId, kind, cmuxId) =>
      Effect.sync(() =>
        Option.fromNullable(resources.find((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId && live(row))),
      ),
    record: (resource) => Effect.gen(function* () {
      if (resource.kind === "mesh" && meshRecordFault.before > 0) { meshRecordFault.before--; return yield* Effect.fail(new StoreError({ operation: "ownership.record", cause: "injected before commit" })); }
      if (resource.kind === "vm" && recordFault.before > 0) { recordFault.before--; return yield* Effect.fail(new StoreError({ operation: "ownership.record", cause: "injected before commit" })); }
      const existing = resources.find((r) => r.cmuxId === resource.cmuxId);
      if (existing && (existing.tenantId !== resource.tenantId || existing.kind !== resource.kind || existing.upstreamId !== resource.upstreamId || existing.createdBy !== resource.createdBy || existing.displayName !== resource.displayName || JSON.stringify(existing.labels) !== JSON.stringify(resource.labels) || JSON.stringify(existing.creation) !== JSON.stringify(resource.creation) || deleted.has(existing.cmuxId))) return yield* Effect.fail(new StoreError({ operation: "ownership.record", cause: "allocation identity conflict" }));
      if (!existing) resources.push({ ...resource, createdAt: resource.kind === "mesh" ? resource.createdAt : nextCreatedAt(resource.createdAt) });
      // Mirrors the SQL: recording the same allocation again may commit it, never uncommit it.
      else if (existing.committed === false && resource.committed !== false) resources[resources.indexOf(existing)] = { ...existing, committed: true };
      if (resource.kind === "mesh" && meshRecordFault.after > 0) { meshRecordFault.after--; return yield* Effect.fail(new StoreError({ operation: "ownership.record", cause: "injected lost commit reply" })); }
      if (resource.kind === "vm" && recordFault.after > 0) { recordFault.after--; return yield* Effect.fail(new StoreError({ operation: "ownership.record", cause: "injected lost commit reply" })); }
    }),
    // Mirrors the SQL: tenant and kind, live rows, newest first by (created_at, cmux_id), keyset after a position.
    listPage: (tenantId, kind, page) =>
      Effect.sync(() =>
        resources
          .filter((row) => row.tenantId === tenantId && row.kind === kind && live(row))
          .filter((row) => page.createdBy === undefined || row.createdBy === page.createdBy)
          .filter((row) => page.only === null || page.only.has(row.cmuxId))
          .filter((row) => page.labels === null || Object.entries(page.labels).every(([key, value]) => row.labels[key] === value))
          .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime() || (a.cmuxId < b.cmuxId ? 1 : -1))
          .filter(
            (row) =>
              page.after === null ||
              row.createdAt.getTime() < page.after.createdAt.getTime() ||
              (row.createdAt.getTime() === page.after.createdAt.getTime() && row.cmuxId < page.after.cmuxId),
          )
          .slice(0, page.limit),
      ),
    countLive: (tenantId, kind) => Effect.sync(() => resources.filter((row) => row.tenantId === tenantId && row.kind === kind && live(row) && row.committed !== false).length),
    markDeleted: (tenantId, kind, cmuxId) =>
      Effect.sync(() => {
        if (resources.some((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId)) deleted.add(cmuxId);
      }),
    findDeleted: (tenantId, kind, cmuxId) =>
      Effect.sync(() =>
        Option.fromNullable(resources.find((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId && !live(row))),
      ),
  });

  const auditStore = Layer.succeed(AuditStore, {
    append: (entry) =>
      Effect.sync(() => {
        audit.push({ tenantId: entry.tenantId, actor: entry.actor, action: entry.action, cmuxId: entry.cmuxId, outcome: entry.outcome, ownerActor: entry.ownerActor });
      }),
  });

  const policy = tenantPolicyLayer({
    ...(options.httpsProxyOrigins === undefined ? {} : { httpsProxyOrigins: options.httpsProxyOrigins }),
    environment: options.environment ?? "local",
    ...(options.devTestTenants === undefined ? {} : { devTestTenantIds: options.devTestTenants }),
    ...(options.maxVms === undefined ? {} : { maxVms: options.maxVms }),
    ...(options.maxSnapshots === undefined ? {} : { maxSnapshots: options.maxSnapshots }),
    ...(options.ratePerMinute === undefined ? {} : { ratePerMinute: options.ratePerMinute }),
    ...(options.maxUploadBytes === undefined ? {} : { maxUploadBytes: options.maxUploadBytes }),
  });

  const entitlements = Layer.succeed(Entitlements, {
    mayCreate: (tenantId) => Effect.sync(() => billed.has(tenantId)),
  });

  const apiKeys = Layer.succeed(ApiKeyStore, {
    findActiveByHash: (hash, now) =>
      Effect.sync(() =>
        Option.fromNullable(
          keys.find((key) => key.hash === hash && !key.revoked && (key.expiresAt === null || key.expiresAt > now)),
        ),
      ),
    findActiveById: (tenantId, id, now) =>
      Effect.sync(() =>
        Option.fromNullable(
          keys.find((key) => key.tenantId === tenantId && key.id === id && !key.revoked && (key.expiresAt === null || key.expiresAt > now)),
        ),
      ),
  });

  /** Snapshot reads and terminals (slice S3a) are served by s3a-fakes.ts; everything else by fake-upstream.ts. */
  const s3a = makeS3aFakes(resources, upstream);
  /** Mesh networking routes (cx-0op) are served by mesh-fakes.ts first. */
  const mesh = makeMeshFakes(upstream, options.mesh);
  const upstreamFetch = async (request: Request): Promise<Response> =>
    (await mesh.upstream(request)) ?? (await s3a.upstream(request)) ?? upstream.fetch(request);

  let configuredImages = parseVmImages(options.bootImages).images;
  const services = Layer.mergeAll(
    ownership,
    apiKeys,
    // Read at request time, so a key added after the harness starts works, as a redeployed secret would.
    Layer.succeed(ServiceKeys, {
      find: (sha256) =>
        Effect.sync(() =>
          Option.map(Option.fromNullable(serviceKeys.find((key) => key.sha256 === sha256)), (key) => ({
            id: key.id,
            sha256: key.sha256,
            scopes: new Set(key.scopes),
            labels: key.labels,
            teams: key.teams === null ? null : new Set(key.teams.map((team) => TenantId.make(team))),
          })),
        ),
    }),
    auditStore,
    policy,
    Layer.succeed(VmImages, { get images() { return configuredImages; } }),
    entitlements,
    options.limits ?? memoryLimitsLayer(),
    Layer.succeed(
      UpstreamClient,
      upstreamClient,
    ),
    Layer.succeed(SessionVerifier, makeStackSessionVerifier({ apiUrl: STACK_API_URL, projectId: STACK_PROJECT_ID, getKey })),
    // The real membership client and shared positive cache (mesh M4), over a fake Stack teams API.
    Layer.succeed(
      TeamMembership,
      makeStackTeamMembership({
        apiUrl: STACK_API_URL,
        projectId: STACK_PROJECT_ID,
        serverKey: Redacted.make("stack-test-server-key"),
        cache: membershipCache.service,
        fetch: stackFetch,
      }),
    ),
    membershipCache.layer,
    webhookDeliveries.layer,
    s3a.layer(upstreamFetch),
    mesh.layer(upstreamFetch),
    Layer.succeed(AgentStore, {
      findAgentKey: (tenantId, id) =>
        Effect.sync(() => {
          const key = keys.find((k) => k.tenantId === tenantId && k.id === id && k.agent !== null);
          return key === undefined || key.agent === null
            ? null
            : { id: key.id, tenantId: key.tenantId, createdBy: key.createdBy ?? "user:test", labels: key.agent.labels, expiresAt: key.expiresAt, revokedAt: key.revokedAt ?? null };
        }),
      revokeAgentKey: (tenantId, id, at) =>
        Effect.sync(() => {
          const index = keys.findIndex((k) => k.tenantId === tenantId && k.id === id && k.agent !== null);
          const found = keys[index];
          if (found === undefined) return false;
          keys[index] = { ...found, revoked: true, revokedAt: found.revokedAt ?? at };
          return true;
        }),
      dueAgentKeys: (now, limit) =>
        Effect.sync(() =>
          keys
            .filter((k) => k.agent !== null && k.cleanedAt === undefined && (k.revoked || (k.expiresAt !== null && k.expiresAt <= now)))
            .slice(0, limit)
            .map((k) => ({ id: k.id, tenantId: k.tenantId, createdBy: k.createdBy ?? "user:test", labels: k.agent?.labels ?? {}, expiresAt: k.expiresAt, revokedAt: k.revokedAt ?? null })),
        ),
      markAgentCleaned: (tenantId, id, at) =>
        Effect.sync(() => {
          const index = keys.findIndex((k) => k.tenantId === tenantId && k.id === id);
          const found = keys[index];
          if (found !== undefined) keys[index] = { ...found, cleanedAt: found.cleanedAt ?? at };
        }),
      insertClientSession: (row) => Effect.sync(() => void clientSessions.push(row)),
      liveClientSessions: (tenantId, vmId) =>
        Effect.sync(() => clientSessions.filter((row) => row.tenantId === tenantId && row.vmId === vmId && row.revokedAt === null)),
      findClientSession: (tenantId, vmId, id) =>
        Effect.sync(() => clientSessions.find((row) => row.tenantId === tenantId && row.vmId === vmId && row.id === id) ?? null),
      markClientSessionRevoked: (tenantId, id, at) =>
        Effect.sync(() => {
          const index = clientSessions.findIndex((row) => row.tenantId === tenantId && row.id === id);
          const found = clientSessions[index];
          if (found !== undefined && found.revokedAt === null) clientSessions[index] = { ...found, revokedAt: at };
        }),
      orphanClientSessions: (limit) =>
        Effect.sync(() => clientSessions.filter((row) => row.revokedAt === null && deleted.has(row.vmId)).slice(0, limit)),
    }),
    Layer.succeed(TeamAdmin, {
      isAdmin: (tenantId, userId) => Effect.sync(() => admins.get(tenantId)?.has(userId) ?? false),
    }),
    Layer.succeed(ApiKeyAdminStore, {
      insert: (key) =>
        Effect.sync(() => {
          keys.push({
            id: key.id,
            tenantId: key.tenantId,
            scopes: key.scopes,
            resourceAllowlist: key.resourceAllowlist,
            hash: key.keyHash,
            revoked: false,
            expiresAt: key.expiresAt,
            name: key.name,
            createdBy: key.createdBy,
            createdAt: key.createdAt,
            agent: key.agent ?? null,
          });
        }),
      list: (tenantId, limit) =>
        Effect.sync(() =>
          keys
            .filter((key) => key.tenantId === tenantId)
            .map((key) => ({
              id: key.id,
              name: key.name ?? "test key",
              scopes: key.scopes,
              resourceAllowlist: key.resourceAllowlist,
              createdBy: key.createdBy ?? "user:test",
              createdAt: key.createdAt ?? new Date(0),
              expiresAt: key.expiresAt,
              revokedAt: key.revokedAt ?? null,
            }))
            .reverse()
            .slice(0, limit),
        ),
      revoke: (tenantId, id, at) =>
        Effect.sync(() => {
          const index = keys.findIndex((key) => key.tenantId === tenantId && key.id === id);
          const found = keys[index];
          if (found === undefined) return false;
          keys[index] = { ...found, revoked: true, revokedAt: found.revokedAt ?? at };
          return true;
        }),
    }),
  );

  const { handler, dispose, reap } = makeWebHandler(
    services,
    options.stackWebhookSecret === undefined ? {} : { stackWebhookSecret: Redacted.make(options.stackWebhookSecret) },
  );

  return {
    dispose,
    upstream,
    /** Every upstream call, in order. */
    upstreamRequests,
    resources,
    recordFault,
    meshRecordFault,
    setProviderConfig(baseUrl = UPSTREAM_URL, apiKey = UPSTREAM_KEY) {
      Object.assign(upstreamClient, makeUpstreamClient({ baseUrl, apiKey: Redacted.make(apiKey), environment: "local", fetch: (request) => upstream.fetch(request) }));
    },
    /** One agent reaper run, as the Worker's cron does. */
    reap,
    /** Client sessions as the database holds them (identity ids, never tokens). */
    clientSessions,
    /** Moves an API key's expiry into the past, as time passing would. */
    expireKey(id: string) {
      const index = keys.findIndex((key) => key.id === id);
      const found = keys[index];
      if (found === undefined) throw new Error("expireKey: no such key");
      keys[index] = { ...found, expiresAt: new Date(Date.now() - 1000) };
    },
    /** Whether the ownership row for `cmuxId` is marked deleted. */
    isDeleted: (cmuxId: string) => deleted.has(cmuxId),
    audit,
    /** Whether `tenant`'s plan allows creating VMs (team_alpha and team_bravo do by default). */
    /** Simulates a redeployed operator catalog while retaining the tenant ledger. */
    setBootImages(raw: string) { configuredImages = parseVmImages(raw).images; },
    setBilling(tenant: string, allowed: boolean) {
      if (allowed) billed.add(tenant);
      else billed.delete(tenant);
    },
    /** Snapshots and terminals (slice S3a): fake stores, audit log, entitlements and terminal sockets. */
    s3a,
    /** Mesh experiment (cx-0op): mesh tables and the provider's networking state. */
    mesh,
    /** Records a VM owned by `tenant` and backed by a fake upstream VM. Returns its public id. */
    addVm(
      tenant: string,
      state = "running",
      labels: Readonly<Record<string, string>> = {},
    ): { readonly vmId: VmId; readonly upstreamId: string } {
      const vmId = newVmId();
      const upstreamId = upstream.addVm(state).id;
      resources.push({
        tenantId: TenantId.make(tenant),
        kind: "vm",
        cmuxId: vmId,
        upstreamId: UpstreamId.make(upstreamId),
        createdBy: "user:test",
        createdAt: nextCreatedAt(new Date()),
        displayName: null,
        labels,
      });
      return { vmId, upstreamId };
    },
    /** Records a snapshot owned by `tenant`, taken from a fake upstream VM. Returns its public id. */
    addSnapshot(tenant: string): { readonly snapshotId: SnapshotId; readonly upstreamId: string } {
      const snapshotId = newSnapshotId();
      const upstreamId = upstream.addSnapshot(upstream.addVm("running").id).id;
      resources.push({
        tenantId: TenantId.make(tenant),
        kind: "snapshot",
        cmuxId: snapshotId,
        upstreamId: UpstreamId.make(upstreamId),
        createdBy: "user:test",
        createdAt: nextCreatedAt(new Date()),
        displayName: null,
        labels: {},
      });
      return { snapshotId, upstreamId };
    },
    /** Removes the upstream VM while keeping its ownership row. */
    dropUpstreamVm(upstreamId: string) {
      upstream.vms.delete(upstreamId);
    },
    /**
     * Configures a service key (cx-b4h.13), as the CMUX_VM_SERVICE_KEYS Worker
     * secret does: no tenant of its own, the given scopes, only resources that
     * carry `labels`, and optionally only some teams. Returns the secret.
     */
    async addServiceKey(
      options: {
        readonly id?: string;
        readonly scopes?: ReadonlyArray<Scope>;
        readonly labels?: Readonly<Record<string, string>>;
        readonly teams?: ReadonlyArray<string>;
      } = {},
    ): Promise<string> {
      const secret = generateApiKey();
      serviceKeys.push({
        id: options.id ?? "cloud-chief",
        sha256: await Effect.runPromise(hashApiKey(secret)),
        scopes: options.scopes ?? ["vm:read", "vm:write", "vm:exec"],
        labels: options.labels ?? { role: "chief" },
        teams: options.teams ?? null,
      });
      return secret;
    },
    /** Issues an API key for `tenant` with `scopes`. Returns the secret, as a client would hold it. */
    async addKey(
      tenant: string,
      scopes: ReadonlyArray<Scope>,
      options: { readonly revoked?: boolean; readonly expiresAt?: Date; readonly allowlist?: ReadonlyArray<string> } = {},
    ): Promise<string> {
      const secret = generateApiKey();
      keys.push({
        id: newApiKeyId(),
        tenantId: TenantId.make(tenant),
        scopes,
        resourceAllowlist: options.allowlist ?? null,
        hash: await Effect.runPromise(hashApiKey(secret)),
        revoked: options.revoked ?? false,
        expiresAt: options.expiresAt ?? null,
        agent: null,
      });
      return secret;
    },
    /** Revokes the API key whose secret is `secret`, as the key management endpoint does. */
    async revokeKey(secret: string) {
      const hash = await Effect.runPromise(hashApiKey(secret));
      const index = keys.findIndex((key) => key.hash === hash);
      const found = keys[index];
      if (found === undefined) throw new Error("revokeKey: no such key");
      keys[index] = { ...found, revoked: true, revokedAt: found.revokedAt ?? new Date() };
    },
    /** Makes `user` a team admin of `tenant` (Stack team_admin). */
    addAdmin(tenant: string, user: string) {
      const set = admins.get(tenant) ?? new Set<string>();
      set.add(user);
      admins.set(tenant, set);
    },
    /** Every stored API key record, as the database would hold it (hashes, never secrets). */
    storedKeys(): ReadonlyArray<StoredKey> {
      return keys;
    },
    /** Membership lookups that reached the (fake) Stack server API, by user id. */
    stackMembershipCalls,
    /** The shared membership cache and the processed webhook deliveries (mesh M4). */
    membershipCache,
    webhookDeliveries,
    /** Stack membership lookups for `user` answer 500 (on) or normally (off). */
    failStackFor(user: string, on = true) {
      if (on) stackFailing.add(user);
      else stackFailing.delete(user);
    },
    /** Removes `user` from `tenant` in the fake Stack directory (no webhook is sent). */
    removeMember(tenant: string, user: string) {
      members.get(tenant)?.delete(user);
    },
    /** Sends a Stack webhook signed with `secret` (default: the harness secret), as Stack (Svix) does. */
    async stackWebhook(
      event: { readonly type: string; readonly data: unknown },
      sign: { readonly id?: string; readonly timestampSeconds?: number; readonly secret?: string; readonly signature?: string } = {},
    ): Promise<Response> {
      const body = JSON.stringify(event);
      const id = sign.id ?? `msg_${crypto.randomUUID()}`;
      const timestamp = String(sign.timestampSeconds ?? Math.floor(Date.now() / 1000));
      const secret = sign.secret ?? options.stackWebhookSecret ?? "";
      const signature = sign.signature ?? `v1,${(await signWebhookContent(Redacted.make(secret), `${id}.${timestamp}.${body}`)) ?? ""}`;
      return handler(
        new Request("https://vm.test/v1/webhooks/stack", {
          method: "POST",
          headers: { "content-type": "application/json", "svix-id": id, "svix-timestamp": timestamp, "svix-signature": signature },
          body,
        }),
      );
    },
    /** Sets a team's Stack server_metadata (for example the cmux VM personal-tenant marker). */
    setStackMetadata(tenant: string, metadata: unknown) {
      stackMetadata.set(tenant, metadata);
    },
    addMember(tenant: string, user: string) {
      const set = members.get(tenant) ?? new Set<string>();
      set.add(user);
      members.set(tenant, set);
    },
    async sessionToken(user: string, options: { readonly expiresIn?: string; readonly key?: SigningKey } = {}): Promise<string> {
      return new SignJWT({ project_id: STACK_PROJECT_ID })
        .setProtectedHeader({ alg: "ES256", kid: "test-key" })
        .setSubject(UserId.make(user))
        .setIssuer(`${STACK_API_URL}/api/v1/projects/${STACK_PROJECT_ID}`)
        .setAudience(STACK_PROJECT_ID)
        .setIssuedAt()
        .setExpirationTime(options.expiresIn ?? "1h")
        .sign(options.key ?? privateKey);
    },
    request(path: string, headers: Record<string, string> = {}, init: { readonly method?: string; readonly body?: unknown } = {}): Promise<Response> {
      const body = init.body === undefined ? null : JSON.stringify(init.body);
      return handler(
        new Request(`https://vm.test${path}`, {
          method: init.method ?? "GET",
          headers: body === null ? headers : { ...headers, "content-type": "application/json" },
          body,
        }),
      );
    },
    /** Sends raw bytes, as a file upload does. */
    send(path: string, headers: Record<string, string>, method: string, bytes: Uint8Array): Promise<Response> {
      return handler(
        new Request(`https://vm.test${path}`, {
          method,
          headers: { ...headers, "content-type": "application/octet-stream", "content-length": String(bytes.length) },
          body: bytes,
        }),
      );
    },
  };
}
