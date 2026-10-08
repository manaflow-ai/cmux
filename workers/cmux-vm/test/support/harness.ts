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
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { Entitlements } from "../../src/proofs/tenant-may-create.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";
import { makeUpstreamClient } from "../../src/upstream/live.ts";
import { makeFakeUpstream } from "./fake-upstream.ts";
import { makeS3aFakes } from "./s3a-fakes.ts";
import { TeamAdmin } from "../../src/auth/team-admin.ts";
import { ApiKeyAdminStore } from "../../src/db/api-keys.ts";
import { makeMeshFakes, type MeshFakeOptions } from "./mesh-fakes.ts";

export const STACK_API_URL = "https://stack.test";
export const STACK_PROJECT_ID = "project-test";
const UPSTREAM_URL = "https://upstream.test";
const UPSTREAM_KEY = "upstream-test-key";

export interface HarnessOptions {
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
}

export async function makeHarness(options: HarnessOptions = {}) {
  const resources: OwnedResource[] = [];
  const keys: StoredKey[] = [];
  const members = new Map<string, Set<string>>();
  /** Team admins (Stack team_admin), per tenant. */
  const admins = new Map<string, Set<string>>();
  const upstream = makeFakeUpstream(UPSTREAM_KEY);
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
    const items = [...members].filter(([, users]) => users.has(user)).map(([team]) => ({ id: team }));
    return Response.json({ items });
  };
  const membershipCache = makeMemoryMembershipCache();
  const webhookDeliveries = makeMemoryWebhookDeliveryStore();

  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "ES256" };
  const getKey = createLocalJWKSet({ keys: [jwk] });

  const ownership = Layer.succeed(OwnershipStore, {
    find: (tenantId, kind, cmuxId) =>
      Effect.sync(() =>
        Option.fromNullable(resources.find((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId && live(row))),
      ),
    record: (resource) => Effect.sync(() => void resources.push({ ...resource, createdAt: nextCreatedAt(resource.createdAt) })),
    // Mirrors the SQL: tenant and kind, live rows, newest first by (created_at, cmux_id), keyset after a position.
    listPage: (tenantId, kind, page) =>
      Effect.sync(() =>
        resources
          .filter((row) => row.tenantId === tenantId && row.kind === kind && live(row))
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
    countLive: (tenantId, kind) => Effect.sync(() => resources.filter((row) => row.tenantId === tenantId && row.kind === kind && live(row)).length),
    markDeleted: (tenantId, kind, cmuxId) =>
      Effect.sync(() => {
        if (resources.some((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId)) deleted.add(cmuxId);
      }),
  });

  const auditStore = Layer.succeed(AuditStore, {
    append: (entry) =>
      Effect.sync(() => {
        audit.push({ tenantId: entry.tenantId, actor: entry.actor, action: entry.action, cmuxId: entry.cmuxId, outcome: entry.outcome, ownerActor: entry.ownerActor });
      }),
  });

  const policy = tenantPolicyLayer({
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

  const services = Layer.mergeAll(
    ownership,
    apiKeys,
    auditStore,
    policy,
    entitlements,
    memoryLimitsLayer(),
    Layer.succeed(
      UpstreamClient,
      makeUpstreamClient({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), environment: "local", fetch: upstream.fetch }),
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

  const { handler, dispose } = makeWebHandler(
    services,
    options.stackWebhookSecret === undefined ? {} : { stackWebhookSecret: Redacted.make(options.stackWebhookSecret) },
  );

  return {
    dispose,
    upstream,
    /** Every upstream call, in order. */
    upstreamRequests,
    resources,
    /** Whether the ownership row for `cmuxId` is marked deleted. */
    isDeleted: (cmuxId: string) => deleted.has(cmuxId),
    audit,
    /** Whether `tenant`'s plan allows creating VMs (team_alpha and team_bravo do by default). */
    setBilling(tenant: string, allowed: boolean) {
      if (allowed) billed.add(tenant);
      else billed.delete(tenant);
    },
    /** Snapshots and terminals (slice S3a): fake stores, audit log, entitlements and terminal sockets. */
    s3a,
    /** Mesh experiment (cx-0op): mesh tables and the provider's networking state. */
    mesh,
    /** Records a VM owned by `tenant` and backed by a fake upstream VM. Returns its public id. */
    addVm(tenant: string, state = "running"): { readonly vmId: VmId; readonly upstreamId: string } {
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
        labels: {},
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
