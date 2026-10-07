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
import { newApiKeyId, newVmId, TenantId, UpstreamId, UserId, type VmId } from "../../src/lib/ids.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";
import { makeUpstreamClient } from "../../src/upstream/live.ts";
import { makeS3aFakes } from "./s3a-fakes.ts";

export const STACK_API_URL = "https://stack.test";
export const STACK_PROJECT_ID = "project-test";
const UPSTREAM_URL = "https://upstream.test";

export interface FakeUpstreamVm {
  readonly id: string;
  readonly state: string;
}

type SigningKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];

interface StoredKey extends ApiKeyRecord {
  readonly hash: string;
  readonly revoked: boolean;
  readonly expiresAt: Date | null;
}

export async function makeHarness() {
  const resources: OwnedResource[] = [];
  const keys: StoredKey[] = [];
  const members = new Map<string, Set<string>>();
  const upstreamVms = new Map<string, FakeUpstreamVm>();
  const upstreamRequests: Request[] = [];

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

  const s3a = makeS3aFakes(resources);

  const upstreamFetch = async (request: Request): Promise<Response> => {
    upstreamRequests.push(request);
    const handled = await s3a.upstream(request);
    if (handled !== null) return handled;
    const url = new URL(request.url);
    const match = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname);
    if (request.headers.get("authorization") !== "Bearer upstream-test-key") {
      return Response.json({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 });
    }
    const vm = match?.[1] === undefined ? undefined : upstreamVms.get(decodeURIComponent(match[1]));
    if (vm === undefined) return Response.json({ code: "NOT_FOUND", message: "no such VM" }, { status: 404 });
    return Response.json({
      id: vm.id,
      slug: `tenant-slug-${vm.id}`,
      snapshotId: `sc-${vm.id}`,
      state: vm.state,
      resources: { cpu: 4, memory: 8192, storage: 16384 },
      idleTimeoutSeconds: 300,
      metadata: { cmuxTenant: "leak-check" },
      createdAt: "2026-10-01T00:00:00Z",
      updatedAt: "2026-10-02T00:00:00Z",
    });
  };

  const services = Layer.mergeAll(
    ownership,
    apiKeys,
    Layer.succeed(
      UpstreamClient,
      makeUpstreamClient({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make("upstream-test-key"), fetch: upstreamFetch }),
    ),
    Layer.succeed(SessionVerifier, makeStackSessionVerifier({ apiUrl: STACK_API_URL, projectId: STACK_PROJECT_ID, getKey })),
    Layer.succeed(TeamMembership, {
      isMember: (tenantId, userId) => Effect.sync(() => members.get(tenantId)?.has(userId) ?? false),
    }),
    s3a.layer(upstreamFetch),
  );

  const { handler, dispose } = makeWebHandler(services);

  return {
    dispose,
    upstreamRequests,
    /** Snapshots and terminals (slice S3a): fake stores, audit log, entitlements and upstream state. */
    s3a,
    /** Records a VM owned by `tenant` and backed by a fake upstream VM. Returns its public id. */
    addVm(tenant: string, state = "running"): { readonly vmId: VmId; readonly upstreamId: string } {
      const vmId = newVmId();
      const upstreamId = `vm-${crypto.randomUUID()}`;
      upstreamVms.set(upstreamId, { id: upstreamId, state });
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
    /** Removes the upstream VM while keeping its ownership row. */
    dropUpstreamVm(upstreamId: string) {
      upstreamVms.delete(upstreamId);
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
  };
}
