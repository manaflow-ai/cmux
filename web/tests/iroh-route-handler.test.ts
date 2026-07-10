import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { IrohDatabaseError, IrohQuotaExceededError } from "../services/iroh/errors";
import { handleIrohRoute } from "../services/iroh/routeHandler";
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
};

describe("Iroh route boundary", () => {
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
    issueEndpointAttestation: unavailable,
    revoke: unavailable,
    issuePairGrant: unavailable,
    issueRelayToken: unavailable,
    ...overrides,
  };
}
