/**
 * Test harness: the real API, handlers, middleware, proofs and session
 * verifier, with in-memory stores, a local JWKS, a fake team directory and a
 * fake upstream provider behind the real upstream client.
 */
import { Effect, Layer, Option, Redacted } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { makeWebHandler } from "../../src/app.ts";
import { generateApiKey, hashApiKey, makeStackSessionVerifier, SessionVerifier, TeamMembership } from "../../src/auth/credentials.ts";
import { ApiKeyStore, OwnershipStore, type ApiKeyRecord, type OwnedResource } from "../../src/db/stores.ts";
import type { Scope } from "../../src/domain/scopes.ts";
import { newApiKeyId, newSnapshotId, newVmId, TenantId, UpstreamId, UserId, type SnapshotId, type VmId } from "../../src/lib/ids.ts";
import { makeUpstreamClient, UpstreamClient } from "../../src/upstream/client.ts";
import { makeFakeUpstream } from "./fake-upstream.ts";

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
  /** Requests per minute per tenant for each limit class. */
  readonly ratePerMinute?: Partial<Record<"read" | "write" | "exec" | "files", number>>;
  /** Largest file upload accepted, in bytes. */
  readonly maxUploadBytes?: number;
}

/** One audit row as a test sees it. */
export interface AuditRow {
  readonly tenantId: string;
  readonly actor: string;
  readonly action: string;
  readonly cmuxId: string | null;
  readonly outcome: string;
}

type SigningKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];

interface StoredKey extends ApiKeyRecord {
  readonly hash: string;
  readonly revoked: boolean;
  readonly expiresAt: Date | null;
}

export async function makeHarness(options: HarnessOptions = {}) {
  const resources: OwnedResource[] = [];
  const keys: StoredKey[] = [];
  const members = new Map<string, Set<string>>();
  const upstream = makeFakeUpstream(UPSTREAM_KEY);
  const upstreamRequests = upstream.calls;
  const audit: AuditRow[] = [];
  /** Tenants whose plan allows creating VMs. */
  const billed = new Set<string>(["team_alpha", "team_bravo"]);
  void options;

  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "ES256" };
  const getKey = createLocalJWKSet({ keys: [jwk] });

  const ownership = Layer.succeed(OwnershipStore, {
    find: (tenantId, kind, cmuxId) =>
      Effect.sync(() =>
        Option.fromNullable(resources.find((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId)),
      ),
    record: (resource) => Effect.sync(() => void resources.push(resource)),
  });

  const apiKeys = Layer.succeed(ApiKeyStore, {
    findActiveByHash: (hash, now) =>
      Effect.sync(() =>
        Option.fromNullable(
          keys.find((key) => key.hash === hash && !key.revoked && (key.expiresAt === null || key.expiresAt > now)),
        ),
      ),
  });

  const services = Layer.mergeAll(
    ownership,
    apiKeys,
    Layer.succeed(
      UpstreamClient,
      makeUpstreamClient({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), fetch: upstream.fetch }),
    ),
    Layer.succeed(SessionVerifier, makeStackSessionVerifier({ apiUrl: STACK_API_URL, projectId: STACK_PROJECT_ID, getKey })),
    Layer.succeed(TeamMembership, {
      isMember: (tenantId, userId) => Effect.sync(() => members.get(tenantId)?.has(userId) ?? false),
    }),
  );

  const { handler, dispose } = makeWebHandler(services);

  return {
    dispose,
    upstream,
    /** Every upstream call, in order. */
    upstreamRequests,
    resources,
    audit,
    /** Whether `tenant`'s plan allows creating VMs (team_alpha and team_bravo do by default). */
    setBilling(tenant: string, allowed: boolean) {
      if (allowed) billed.add(tenant);
      else billed.delete(tenant);
    },
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
        createdAt: new Date(),
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
        createdAt: new Date(),
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
