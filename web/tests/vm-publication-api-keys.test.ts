import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  CloudVmPublicationRepository,
  PublicationConflictError,
  PublicationNotFoundError,
  type CloudVmPublicationApiKeyRow,
  type CloudVmPublicationRepositoryShape,
  type CloudVmPublicationRow,
  type CloudVmPublicationTarget,
} from "../services/vm-publications/repository";
import {
  VmPublicationProvider,
  type VmPublicationProviderShape,
} from "../services/vm-publications/provider";
import {
  createPublicationApiKey,
  provisionPublicationApi,
  revokePublicationApiKey,
} from "../services/vm-publications/apiKeys";
import {
  evaluatePublicationRequest,
  PublicationViewerResolver,
  type PublicationViewerResolverShape,
} from "../services/vm-publications/auth";
import { PublicationAuthRepository } from "../services/vm-publications/authRepository";
import {
  PUBLICATION_API_KEY_COOKIE,
  hashPublicationToken,
  isPublicationApiKey,
  randomPublicationApiKey,
} from "../services/vm-publications/security";
import { handleApiProvision } from "../app/api/vm/apis/route";
import { handleApiKeyRevoke } from "../app/api/vm/publications/[id]/api-keys/[keyId]/route";
import { handleForwardAuthRequest, type ForwardAuthHandlerDependencies } from "../app/api/freestyle/forward-auth/route";
import type { PublicationWorkflowRunner } from "../app/api/vm/publications/routeShared";

const NOW = new Date("2026-10-26T12:00:00.000Z");
const PUBLICATION_ID = "10000000-0000-4000-8000-000000000001";
const KEY_ID = "20000000-0000-4000-8000-000000000002";
const principal = { userId: "owner-1", teamIds: [] as string[] };

function publication(accessMode: "personal" | "team" | "public", overrides: Partial<CloudVmPublicationRow> = {}): CloudVmPublicationRow {
  return {
    id: PUBLICATION_ID,
    ownerUserId: "owner-1",
    vmId: "db-vm-1",
    domainId: null,
    hostname: "hello--owner--3000.cmux.sh",
    hostnameClaimedAt: NOW,
    port: 3_000,
    accessMode,
    teamId: accessMode === "team" ? "team-1" : null,
    providerTlsRuleId: "tls-rule-1",
    providerForwardAuthId: accessMode === "public" ? null : "forward-auth-shared",
    routingRevision: 1,
    state: "active",
    createdAt: NOW,
    updatedAt: NOW,
    disabledAt: null,
    ...overrides,
  } as CloudVmPublicationRow;
}

function target(row: CloudVmPublicationRow, billingTeamId: string | null = "owner-1"): CloudVmPublicationTarget {
  return {
    publication: row,
    domain: null,
    vm: { id: "db-vm-1", provider: "freestyle", providerVmId: "vm-provider-1", userId: "owner-1", billingTeamId } as CloudVmPublicationTarget["vm"],
  };
}

function keyRow(overrides: Partial<CloudVmPublicationApiKeyRow> = {}): CloudVmPublicationApiKeyRow {
  return {
    id: KEY_ID, publicationId: PUBLICATION_ID, ownerUserId: "owner-1", name: "API key",
    tokenHash: "0".repeat(64), tokenHint: "abcd", expiresAt: null, revokedAt: null, createdAt: NOW,
    ...overrides,
  };
}

function strict<T extends object>(overrides: Partial<T>, label: string): T {
  return new Proxy(overrides as T, {
    get(object, property, receiver) {
      if (Reflect.has(object, property)) return Reflect.get(object, property, receiver);
      return () => { throw new Error(`unexpected ${label} call: ${String(property)}`); };
    },
  });
}

/** The repository and provider calls that bring the shared forward-auth config current. */
function forwardAuthCalls(calls: string[]) {
  return {
    repository: {
      claimProviderForwardAuth: () => {
        calls.push("claimForwardAuth");
        return Effect.succeed({ kind: "claimed" as const, config: { providerForwardAuthId: "forward-auth-shared" } as never });
      },
      completeProviderForwardAuth: () => Effect.succeed({ providerForwardAuthId: "forward-auth-shared" } as never),
    } satisfies Partial<CloudVmPublicationRepositoryShape>,
    provider: {
      ensureSharedForwardAuth: () => {
        calls.push("ensureSharedForwardAuth");
        return Effect.succeed({ forwardAuthId: "forward-auth-shared", disposition: "updated" as const });
      },
    } satisfies Partial<VmPublicationProviderShape>,
  };
}

const forwardAuth = { url: "https://cmux.com/api/freestyle/forward-auth", serviceToken: "service-secret" };

function runWorkflow<A, E>(
  program: Effect.Effect<A, E, CloudVmPublicationRepository | VmPublicationProvider>,
  repository: Partial<CloudVmPublicationRepositoryShape>,
  provider: Partial<VmPublicationProviderShape> = {},
): Promise<A> {
  return Effect.runPromise(program.pipe(
    Effect.provideService(CloudVmPublicationRepository, strict(repository, "repository")),
    Effect.provideService(VmPublicationProvider, strict(provider, "provider")),
  ));
}

/** The typed failure of a workflow; runPromise would wrap it in a FiberFailure. */
function workflowFailure<A, E>(
  program: Effect.Effect<A, E, CloudVmPublicationRepository | VmPublicationProvider>,
  repository: Partial<CloudVmPublicationRepositoryShape>,
  provider: Partial<VmPublicationProviderShape> = {},
): Promise<E> {
  return runWorkflow(Effect.flip(program), repository, provider);
}

function runAuth<A, E, R>(
  program: Effect.Effect<A, E, R>,
  repository: Partial<CloudVmPublicationRepositoryShape>,
  viewerResolver: PublicationViewerResolverShape = { resolve: () => Effect.die("unexpected identity lookup") },
): Promise<A> {
  const runtime = Layer.merge(
    Layer.succeed(PublicationAuthRepository, repository as never),
    Layer.succeed(PublicationViewerResolver, viewerResolver),
  );
  return Effect.runPromise(program.pipe(Effect.provide(runtime as Layer.Layer<R>)));
}

describe("publication API keys", () => {
  test("mints a recognizable key that is stored only as its hash", () => {
    const key = randomPublicationApiKey();
    expect(isPublicationApiKey(key)).toBe(true);
    expect(key.startsWith("cmux_api_")).toBe(true);
    // A __Host- cookie cannot be planted by a sibling host with Domain=.
    expect(PUBLICATION_API_KEY_COOKIE).toBe("__Host-cmux-api-key");
    expect(isPublicationApiKey(`${key}x`)).toBe(false);
    expect(isPublicationApiKey("cmux_api_short")).toBe(false);
    expect(isPublicationApiKey(null)).toBe(false);
  });

  test("protects the key cookie at the edge before minting, and answers the key once", async () => {
    const calls: string[] = [];
    const created: Parameters<CloudVmPublicationRepositoryShape["createApiKey"]>[0][] = [];
    const fa = forwardAuthCalls(calls);
    const minted = await runWorkflow(createPublicationApiKey({
      principal, publicationId: PUBLICATION_ID, name: "  ci  ", forwardAuth, now: NOW,
    }), {
      ...fa.repository,
      findOwnedPublication: () => Effect.succeed(target(publication("personal"))),
      createApiKey: (input) => {
        calls.push("createApiKey");
        created.push(input);
        return Effect.succeed(keyRow({ name: input.name, tokenHash: input.tokenHash, tokenHint: input.tokenHint }));
      },
    }, fa.provider);
    expect(calls).toEqual(["claimForwardAuth", "ensureSharedForwardAuth", "createApiKey"]);
    expect(isPublicationApiKey(minted.token)).toBe(true);
    expect(created[0]).toMatchObject({ name: "ci", ownerUserId: "owner-1", tokenHash: hashPublicationToken(minted.token), tokenHint: minted.token.slice(-4) });
    expect(minted.cookie).toBe(`${PUBLICATION_API_KEY_COOKIE}=${minted.token}`);
    expect(minted.apiKey).toEqual({
      id: KEY_ID, publicationId: PUBLICATION_ID, name: "ci", hint: minted.token.slice(-4),
      createdAt: NOW.toISOString(), expiresAt: null, revokedAt: null,
    });
    expect(JSON.stringify(minted.apiKey)).not.toContain(minted.token);
  });

  test("refuses a key on a public publication, which a key could not restrict", async () => {
    expect(await workflowFailure(createPublicationApiKey({ principal, publicationId: PUBLICATION_ID, forwardAuth, now: NOW }), {
      findOwnedPublication: () => Effect.succeed(target(publication("public"))),
    })).toMatchObject({ reason: "publication_public" });
  });

  test("refuses bad names and past expiries before touching the publication", async () => {
    expect(await workflowFailure(createPublicationApiKey({ principal, publicationId: PUBLICATION_ID, name: "a\nb", now: NOW }), {}))
      .toMatchObject({ reason: "invalid_api_key_name", field: "name" });
    expect(await workflowFailure(createPublicationApiKey({ principal, publicationId: PUBLICATION_ID, expiresAt: "2026-01-01T00:00:00Z", now: NOW }), {}))
      .toMatchObject({ reason: "invalid_expiry", field: "expiresAt" });
  });

  test("revokes only a key of a publication the caller still owns in this account", async () => {
    const revoked = await runWorkflow(revokePublicationApiKey({ principal, publicationId: PUBLICATION_ID, keyId: ` ${KEY_ID} `, now: NOW }), {
      findOwnedPublication: () => Effect.succeed(target(publication("personal"))),
      revokeApiKey: (input) => {
        expect(input).toEqual({ publicationId: PUBLICATION_ID, ownerUserId: "owner-1", keyId: KEY_ID, now: NOW });
        return Effect.succeed(keyRow({ revokedAt: NOW }));
      },
    });
    expect(revoked.revokedAt).toBe(NOW.toISOString());
    // A malformed id names no key and never reaches the uuid column.
    expect(await workflowFailure(revokePublicationApiKey({ principal, publicationId: PUBLICATION_ID, keyId: "not-a-uuid", now: NOW }), {}))
      .toMatchObject({ resource: "api_key" });
    // A team VM whose team the caller has left is not theirs to manage.
    expect(await workflowFailure(revokePublicationApiKey({ principal, publicationId: PUBLICATION_ID, keyId: KEY_ID, now: NOW }), {
      findOwnedPublication: () => Effect.succeed(target(publication("personal"), "team-1")),
    })).toBeInstanceOf(PublicationNotFoundError);
  });

  test("the revoke route answers 404 with product copy for an unknown key", async () => {
    const run: PublicationWorkflowRunner = () => Promise.reject(new PublicationNotFoundError({ resource: "api_key" }));
    const { publicationErrorResponse } = await import("../app/api/vm/publications/routeShared");
    const response = await handleApiKeyRevoke(PUBLICATION_ID, KEY_ID, { principal, run }).catch((error: unknown) => publicationErrorResponse(error));
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: "vm_publication_not_found", reason: "api_key" });
  });
});

describe("one-call API provisioning", () => {
  test("publishes the port protected and answers its URL with a working key", async () => {
    const calls: string[] = [];
    const fa = forwardAuthCalls(calls);
    const reserved = target(publication("personal"));
    const result = await runWorkflow(provisionPublicationApi({
      principal: { ...principal, billingTeamId: "owner-1" }, providerVmId: "vm-provider-1", port: 3_000, name: "agent", forwardAuth, now: NOW,
    }), {
      ...fa.repository,
      reserveManagedPublication: (input) => {
        calls.push(`reserve:${input.accessMode}`);
        return Effect.succeed(reserved);
      },
      findOwnedPublication: () => Effect.succeed(reserved),
      createApiKey: (input) => {
        calls.push("createApiKey");
        return Effect.succeed(keyRow({ name: input.name, tokenHint: input.tokenHint }));
      },
    }, fa.provider);
    expect(calls).toEqual(["reserve:personal", "claimForwardAuth", "ensureSharedForwardAuth", "createApiKey"]);
    expect(result.url).toBe("https://hello--owner--3000.cmux.sh");
    expect(result.publication.accessMode).toBe("personal");
    expect(isPublicationApiKey(result.token)).toBe(true);
    expect(result.apiKey.name).toBe("agent");
  });

  test("a retry that asks for other access than the live publication is refused, not ignored", async () => {
    const live = target(publication("personal"));
    expect(await workflowFailure(provisionPublicationApi({
      principal: { ...principal, teamIds: ["team-1"] }, providerVmId: "vm-provider-1", port: 3_000, accessMode: "team", teamId: "team-1", forwardAuth, now: NOW,
    }), {
      reserveManagedPublication: () => Effect.succeed(live),
    })).toMatchObject({ reason: "publication_access_mismatch" });
  });

  test("refuses public access and bad key input before publishing anything", async () => {
    for (const input of [{ accessMode: "public" as never }, { name: "" }, { expiresAt: "not a date" }]) {
      expect(await workflowFailure(provisionPublicationApi({
        principal, providerVmId: "vm-provider-1", port: 3_000, forwardAuth, now: NOW, ...input,
      }), {})).toMatchObject({ _tag: "PublicationInputError" });
    }
  });

  test("the route requires a machine id and answers no-store", async () => {
    const missing = await handleApiProvision(new Request("https://cmux.com/api/vm/apis", {
      method: "POST", body: JSON.stringify({ port: 3000 }),
    }), { principal, run: () => Promise.reject(new Error("unreachable")) });
    expect(missing.status).toBe(400);
    expect(await missing.json()).toMatchObject({ details: { field: "vmId" } });

    let program: unknown;
    const ok = await handleApiProvision(new Request("https://cmux.com/api/vm/apis", {
      method: "POST", body: JSON.stringify({ vmId: "vm-provider-1", port: 3000 }),
    }), { principal, run: (p) => { program = p; return Promise.resolve({ url: "https://x.cmux.sh", token: "t" } as never); } }, {
      CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET: "secret", CMUX_VM_PUBLICATION_AUTH_ORIGIN: "https://cmux.com",
    } as unknown as NodeJS.ProcessEnv);
    expect(program).toBeDefined();
    expect(ok.status).toBe(201);
    expect(ok.headers.get("cache-control")).toBe("no-store");
  });
});

describe("forward auth with an API key", () => {
  const key = randomPublicationApiKey();

  function requestContext(row: CloudVmPublicationRow, apiKey: { id: string; ownerUserId: string } | null, billingTeamId: string | null = "owner-1") {
    const reads: unknown[] = [];
    return {
      reads,
      repository: {
        findRequestContext: (input: unknown) => {
          reads.push(input);
          return Effect.succeed({ ...target(row, billingTeamId), session: null, apiKey } as never);
        },
      } satisfies Partial<CloudVmPublicationRepositoryShape>,
    };
  }

  test("allows a live key of a personal VM without an identity lookup", async () => {
    const context = requestContext(publication("personal"), { id: KEY_ID, ownerUserId: "owner-1" });
    const result = await runAuth(evaluatePublicationRequest({ providerTlsRuleId: "tls-rule-1", method: "POST", sessionToken: null, apiKey: key, now: NOW }), context.repository);
    expect(result).toEqual({ kind: "allow" });
    expect(context.reads).toEqual([{ providerTlsRuleId: "tls-rule-1", sessionTokenHash: null, apiKeyHash: hashPublicationToken(key), now: NOW }]);
  });

  test("a revoked, expired or unknown key gets 401, never a sign-in redirect", async () => {
    const context = requestContext(publication("team"), null);
    for (const method of ["GET", "POST"]) {
      expect(await runAuth(evaluatePublicationRequest({ providerTlsRuleId: "tls-rule-1", method, sessionToken: null, apiKey: key, now: NOW }), context.repository))
        .toEqual({ kind: "unauthorized" });
    }
    // A malformed cookie is never hashed or looked up, and is no key: a browser
    // that carries junk in it still gets the sign-in handoff.
    const malformed = await runAuth(evaluatePublicationRequest({ providerTlsRuleId: "tls-rule-1", method: "GET", sessionToken: null, apiKey: "guess", now: NOW }), context.repository);
    expect(malformed.kind).toBe("sign_in_required");
    expect((context.reads.at(-1) as { apiKeyHash: unknown }).apiKeyHash).toBeNull();
  });

  test("a team VM key stops working when its owner leaves the team", async () => {
    const context = requestContext(publication("personal"), { id: KEY_ID, ownerUserId: "owner-1" }, "team-1");
    let teamIds = ["team-1"];
    const check = () => runAuth(evaluatePublicationRequest({ providerTlsRuleId: "tls-rule-1", method: "GET", sessionToken: null, apiKey: key, now: NOW }),
      context.repository, { resolve: (userId) => Effect.succeed({ userId, teamIds }) });
    expect(await check()).toEqual({ kind: "allow" });
    teamIds = [];
    expect(await check()).toEqual({ kind: "unauthorized" });
  });

  test("a browser without a key still gets the sign-in handoff", async () => {
    const context = requestContext(publication("personal"), null);
    const result = await runAuth(evaluatePublicationRequest({ providerTlsRuleId: "tls-rule-1", method: "GET", sessionToken: null, now: NOW }), context.repository);
    expect(result.kind).toBe("sign_in_required");
  });

  test("the route reads the key from its cookie and answers 401 without minting a transaction", async () => {
    const seen: unknown[] = [];
    const dependencies: ForwardAuthHandlerDependencies = {
      serviceSecret: "service-secret",
      authPageOrigin: "https://cmux.com",
      resolve: () => Promise.reject(new Error("unexpected resolve")),
      evaluate: (input) => { seen.push(input); return Promise.resolve({ kind: "unauthorized" }); },
      rateLimit: () => Promise.reject(new Error("unexpected rate limit")),
      begin: () => Promise.reject(new Error("unexpected begin")),
      complete: () => Promise.reject(new Error("unexpected complete")),
    };
    const response = await handleForwardAuthRequest(new Request("https://cmux.com/api/freestyle/forward-auth", {
      headers: {
        authorization: "Bearer service-secret",
        "x-forwarded-proto": "https",
        "x-forwarded-method": "GET",
        "x-forwarded-uri": "/v1/items",
        "x-freestyle-tls-rule-id": "tls-rule-1",
        cookie: `other=1; ${PUBLICATION_API_KEY_COOKIE}=${key}`,
      },
    }), dependencies);
    expect(response.status).toBe(401);
    expect(response.headers.get("location")).toBeNull();
    expect(seen).toEqual([{ providerTlsRuleId: "tls-rule-1", method: "GET", sessionToken: null, apiKey: key }]);
  });
});

test("conflict copy names the API key limit and public publications", async () => {
  const { publicationErrorResponse } = await import("../app/api/vm/publications/routeShared");
  for (const reason of ["publication_public", "publication_access_mismatch", "api_key_limit"] as const) {
    const response = publicationErrorResponse(new PublicationConflictError({ reason }));
    expect(response.status).toBe(409);
    const body = await response.json() as { message: string; reason: string };
    expect(body.reason).toBe(reason);
    expect(body.message).not.toContain("conflicts with existing state");
  }
});
