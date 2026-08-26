import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { IrohDatabaseError, IrohQuotaExceededError } from "../services/iroh/errors";
import {
  buildConnectivityInvalidationRequest,
  handleIrohRoute,
} from "../services/iroh/routeHandler";
import type { IrohTrustBrokerShape } from "../services/iroh/trustBroker";
import type { AuthedUser } from "../services/vms/auth";
import { GET as retentionGet } from "../app/api/internal/iroh/retention/route";

const USER: AuthedUser = {
  id: "personal-user-id",
  displayName: null,
  primaryEmail: null,
  billingCustomerType: "team",
  billingTeamId: "selected-team-id",
  selectedTeamId: "selected-team-id",
  teams: [{ id: "selected-team-id", displayName: null, billingPlanId: null }],
  teamIds: ["selected-team-id"],
      userBillingPlanId: null,
      billingPlanId: null,
      resolveSubrouterPermissions: async () => ({
        use: false,
        manageAccounts: false,
      }),
};

describe("Iroh route boundary", () => {
  test("builds an account-authenticated backend-only invalidation", async () => {
    const publication = buildConnectivityInvalidationRequest(
      authedPost("/api/devices/iroh/register", {}),
      7,
      {
        baseURL: "https://presence.example.test/dev",
        publisherSecret: "s".repeat(64),
      },
    );

    expect(publication?.url).toBe(
      "https://presence.example.test/v1/connectivity/invalidate",
    );
    expect(publication?.headers.get("authorization")).toBe("Bearer test-access");
    expect(
      publication?.headers.get("x-cmux-connectivity-publisher-secret"),
    ).toBe("s".repeat(64));
    expect(await publication?.json()).toEqual({ revision: 7 });
    expect(buildConnectivityInvalidationRequest(
      authedPost("/api/devices/iroh/register", {}),
      7,
      { baseURL: "https://presence.example.test" },
    )).toBeNull();
  });

  test("publishes committed registration and revocation revisions", async () => {
    const published: Array<{ authorization: string | null; revision: number }> = [];
    const publishConnectivityInvalidation = async (request: Request, revision: number) => {
      published.push({
        authorization: request.headers.get("authorization"),
        revision,
      });
    };
    const register = await handleIrohRoute(
      authedPost("/api/devices/iroh/register", {}),
      "register",
      {
        verify: async () => USER,
        broker: broker({ register: () => Effect.succeed({ revision: 7 }) }),
        publishConnectivityInvalidation,
      },
    );
    const revoke = await handleIrohRoute(
      authedPost("/api/devices/iroh", {}),
      "revoke",
      {
        verify: async () => USER,
        broker: broker({ revoke: () => Effect.succeed({ revoked: true, revision: 8 }) }),
        publishConnectivityInvalidation,
      },
    );

    expect(register.status).toBe(201);
    expect(revoke.status).toBe(200);
    expect(published).toEqual([
      { authorization: "Bearer test-access", revision: 7 },
      { authorization: "Bearer test-access", revision: 8 },
    ]);
  });

  test("keeps a committed mutation successful when invalidation delivery fails", async () => {
    const response = await handleIrohRoute(
      authedPost("/api/devices/iroh/register", {}),
      "register",
      {
        verify: async () => USER,
        broker: broker({ register: () => Effect.succeed({ revision: 9 }) }),
        publishConnectivityInvalidation: async () => {
          throw new Error("presence unavailable");
        },
      },
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ revision: 9 });
  });

  test("returns a committed mutation before deferred invalidation delivery settles", async () => {
    let releasePublication: (() => void) | undefined;
    let scheduledPublication:
      | (() => Promise<void>)
      | undefined;
    const publicationGate = new Promise<void>((resolve) => {
      releasePublication = () => resolve();
    });
    let responseSettled = false;
    const responsePromise = handleIrohRoute(
      authedPost("/api/devices/iroh/register", {}),
      "register",
      {
        verify: async () => USER,
        broker: broker({ register: () => Effect.succeed({ revision: 10 }) }),
        publishConnectivityInvalidation: async () => {
          await publicationGate;
        },
        scheduleAfterResponse: (operation: () => Promise<void>) => {
          scheduledPublication = operation;
        },
      },
    ).then((response) => {
      responseSettled = true;
      return response;
    });

    for (let attempt = 0; attempt < 50 && !responseSettled; attempt += 1) {
      await Promise.resolve();
    }
    const settledBeforePublication = responseSettled;
    releasePublication?.();
    await scheduledPublication?.();
    const response = await responsePromise;

    expect(settledBeforePublication).toBe(true);
    expect(response.status).toBe(201);
  });

  test("never publishes reads or failed mutations", async () => {
    let published = 0;
    const publishConnectivityInvalidation = async () => {
      published += 1;
    };
    const discover = await handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh"),
      "discover",
      {
        verify: async () => USER,
        broker: broker({ discover: () => Effect.succeed({ revision: 10, bindings: [] }) }),
        publishConnectivityInvalidation,
      },
    );
    const failed = await handleIrohRoute(
      authedPost("/api/devices/iroh", {}),
      "revoke",
      {
        verify: async () => USER,
        broker: broker({
          revoke: () => Effect.fail(new IrohDatabaseError({
            operation: "revoke",
            cause: { category: "connection" },
          })),
        }),
        publishConnectivityInvalidation,
      },
    );

    expect(discover.status).toBe(200);
    expect(failed.status).toBe(503);
    expect(published).toBe(0);
  });

  test("requires authentication before returning the public verification-key set", async () => {
    let called = false;
    const response = await handleIrohRoute(new Request("https://cmux.test/api/devices/iroh"), "discover", {
      verify: async () => null,
      broker: broker({
        discover: () => {
          called = true;
          return Effect.succeed({ grant_verification_keys: { version: 1, keys: [] } });
        },
      }),
    });
    expect(response.status).toBe(401);
    expect(called).toBe(false);
  });

  test("rejects malformed discovery cursors before broker work", async () => {
    let brokerCalled = false;
    const response = await handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh?page_size=128&cursor=not-a-cursor"),
      "discover",
      {
        verify: async () => USER,
        broker: broker({
          discover: () => {
            brokerCalled = true;
            return Effect.succeed({ bindings: [] });
          },
        }),
      },
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_discovery_cursor" });
    expect(brokerCalled).toBe(false);
  });

  test("rejects oversized discovery pages before broker work", async () => {
    let brokerCalled = false;
    const response = await handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh?page_size=129"),
      "discover",
      {
        verify: async () => USER,
        broker: broker({
          discover: () => {
            brokerCalled = true;
            return Effect.succeed({ bindings: [] });
          },
        }),
      },
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_discovery_page_size" });
    expect(brokerCalled).toBe(false);
  });

  test("authenticates before reading an oversized body", async () => {
    let called = false;
    const response = await handleIrohRoute(new Request("https://cmux.test/api/devices/iroh/challenge", {
      method: "POST",
      body: "x".repeat(70_000),
    }), "challenge", {
      verify: async () => null,
      broker: broker({ issueChallenge: () => { called = true; return Effect.succeed({}); } }),
    });
    expect(response.status).toBe(401);
    expect(called).toBe(false);
  });

  test("caps a chunked body while streaming and rejects a missing body", async () => {
    let called = false;
    const chunk = new Uint8Array(40_000);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(chunk);
        controller.enqueue(chunk);
        controller.close();
      },
    });
    const oversizedInit: RequestInit & { duplex: "half" } = {
      method: "POST",
      headers: {
        authorization: "Bearer test-access",
        "x-stack-refresh-token": "test-refresh",
        "content-type": "application/json",
      },
      body: stream,
      duplex: "half",
    };
    const oversized = await handleIrohRoute(new Request(
      "https://cmux.test/api/devices/iroh/challenge",
      oversizedInit,
    ), "challenge", {
      verify: async () => USER,
      broker: broker({ issueChallenge: () => { called = true; return Effect.succeed({}); } }),
    });
    expect(oversized.status).toBe(413);
    expect(called).toBe(false);

    const missing = await handleIrohRoute(new Request("https://cmux.test/api/devices/iroh/challenge", {
      method: "POST",
      headers: {
        authorization: "Bearer test-access",
        "x-stack-refresh-token": "test-refresh",
        "content-type": "application/json",
      },
    }), "challenge", {
      verify: async () => USER,
      broker: broker(),
    });
    expect(missing.status).toBe(400);
    expect(await missing.json()).toEqual({ error: "missing_body" });
  });

  test("uses exact personal user id and ignores selected team membership", async () => {
    let receivedUserId = "";
    const response = await handleIrohRoute(new Request("https://cmux.test/api/devices/iroh", {
      method: "GET",
    }), "discover", {
      verify: async () => USER,
      broker: broker({
        discover: (userId) => {
          receivedUserId = userId;
          return Effect.succeed({ bindings: [] });
        },
      }),
    });
    expect(response.status).toBe(200);
    expect(receivedUserId).toBe("personal-user-id");
    expect(receivedUserId).not.toBe("selected-team-id");
  });

  test("forwards the exact app namespace to every mutation", async () => {
    const received: string[] = [];
    const receivedBindingIDs: string[] = [];
    const namespaced = (
      _userId: string,
      _raw: unknown,
      _now?: Date,
      clientNamespace?: string,
      bindingProof?: { bindingId: string },
    ) => {
      received.push(clientNamespace ?? "");
      receivedBindingIDs.push(bindingProof?.bindingId ?? "");
      return Effect.succeed({});
    };
    const namespacedBroker = broker({
      issueEndpointAttestation: namespaced,
      revoke: namespaced,
      issuePairGrant: namespaced,
      issueRelayToken: namespaced,
    });
    const operations = [
      "endpoint_attestation",
      "revoke",
      "pair_grant",
      "relay_token",
    ] as const;
    for (const operation of operations) {
      const base = authedPost("/api/devices/iroh", {});
      const headers = new Headers(base.headers);
      headers.set("x-cmux-app-namespace", "dev.cmux.app.demo");
      headers.set(
        "x-cmux-iroh-binding-id",
        "123e4567-e89b-42d3-a456-426614174000",
      );
      headers.set("x-cmux-iroh-request-time", "1785384000");
      headers.set("x-cmux-iroh-request-signature", "A".repeat(86));
      const response = await handleIrohRoute(
        new Request(base, { headers }),
        operation,
        { verify: async () => USER, broker: namespacedBroker },
      );
      expect(response.status).toBe(operation === "revoke" ? 200 : 201);
    }
    expect(received).toEqual(Array(4).fill("dev.cmux.app.demo"));
    expect(receivedBindingIDs).toEqual(
      Array(4).fill("123e4567-e89b-42d3-a456-426614174000"),
    );
  });

  test("maps DB-authoritative quota failures to typed 429 with Retry-After", async () => {
    const response = await handleIrohRoute(authedPost("/api/devices/iroh/relay-token", {
      bindingId: "30000000-0000-4000-8000-000000000001",
    }), "relay_token", {
      verify: async () => USER,
      broker: broker({
        issueRelayToken: () => Effect.fail(new IrohQuotaExceededError({
          code: "relay_endpoint_10m_quota",
          retryAfterSeconds: 417,
        })),
      }),
    });
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("417");
    expect(await response.json()).toEqual({
      error: "relay_endpoint_10m_quota",
      retry_after_seconds: 417,
    });
  });

  test("does not expose database implementation details in service failures", async () => {
    const response = await handleIrohRoute(authedPost("/api/devices/iroh/challenge", {}), "challenge", {
      verify: async () => USER,
      broker: broker({
        issueChallenge: () => Effect.fail(new IrohDatabaseError({
          operation: "issue_challenge",
          cause: { category: "connection" },
        })),
      }),
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "iroh_service_unavailable" });
  });
});

describe("Iroh retention route", () => {
  test("fails closed without the cron secret and rejects a wrong token", async () => {
    const previous = process.env.CRON_SECRET;
    try {
      delete process.env.CRON_SECRET;
      expect((await retentionGet(new Request("https://cmux.test/api/internal/iroh/retention"))).status).toBe(503);
      process.env.CRON_SECRET = "expected-secret";
      expect((await retentionGet(new Request("https://cmux.test/api/internal/iroh/retention", {
        headers: { authorization: "Bearer wrong-secret" },
      }))).status).toBe(401);
    } finally {
      if (previous === undefined) delete process.env.CRON_SECRET;
      else process.env.CRON_SECRET = previous;
    }
  });
});

function authedPost(path: string, body: unknown): Request {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: {
      authorization: "Bearer test-access",
      "x-stack-refresh-token": "test-refresh",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function broker(overrides: Partial<IrohTrustBrokerShape> = {}): IrohTrustBrokerShape {
  const unavailable = () => Effect.die(new Error("unexpected broker operation"));
  return {
    issueChallenge: unavailable,
    register: unavailable,
    discover: unavailable,
    discoverComplete: unavailable,
    discoverScoped: unavailable,
    issueEndpointAttestation: unavailable,
    revoke: unavailable,
    issuePairGrant: unavailable,
    issueRelayToken: unavailable,
    ...overrides,
  };
}
