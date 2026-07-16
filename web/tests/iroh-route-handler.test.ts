import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { IrohDatabaseError, IrohQuotaExceededError } from "../services/iroh/errors";
import type { IrohFirewallCheck } from "../services/iroh/firewall";
import { handleIrohRoute, IrohFirewallAdmission } from "../services/iroh/routeHandler";
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

  test("fails closed when the firewall check rejects", async () => {
    let brokerCalled = false;
    const dependencies = {
      verify: async () => USER,
      broker: broker({
        discover: () => {
          brokerCalled = true;
          return Effect.succeed({ bindings: [] });
        },
      }),
      firewall: {
        id: "iroh-test-rule",
        check: async () => {
          throw new Error("firewall unavailable");
        },
      },
    };

    const response = await handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh"),
      "discover",
      dependencies,
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "iroh_service_unavailable" });
    expect(brokerCalled).toBe(false);
  });

  test("bounds a firewall check that never settles", async () => {
    let brokerCalled = false;
    let aborted = false;
    const check: IrohFirewallCheck = (_id, { signal }) => new Promise<never>((_resolve, reject) => {
      signal.addEventListener("abort", () => {
        aborted = true;
        reject(signal.reason);
      }, { once: true });
    });
    const dependencies = {
      verify: async () => USER,
      broker: broker({
        discover: () => {
          brokerCalled = true;
          return Effect.succeed({ bindings: [] });
        },
      }),
      firewall: {
        id: "iroh-test-rule",
        timeoutMs: 10,
        check,
      },
    };

    const response = await handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh"),
      "discover",
      dependencies,
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "iroh_service_unavailable" });
    expect(brokerCalled).toBe(false);
    expect(aborted).toBe(true);
  });

  test("caps timed-out firewall work per identity and across the worker", async () => {
    const admission = new IrohFirewallAdmission(2);
    let started = 0;
    let aborted = 0;
    const check: IrohFirewallCheck = (_id, { signal }) => {
      started += 1;
      return new Promise<never>((_resolve, reject) => {
        signal.addEventListener("abort", () => {
          aborted += 1;
          reject(signal.reason);
        }, { once: true });
      });
    };
    const firewall = {
      id: "iroh-test-rule",
      timeoutMs: 5,
      admission,
      check,
    };
    const discover = (userId: string) => handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh"),
      "discover",
      {
        verify: async () => ({ ...USER, id: userId }),
        broker: broker({ discover: () => Effect.succeed({ bindings: [] }) }),
        firewall,
      },
    );

    const responses = await Promise.all([
      discover("user-1"),
      discover("user-1"),
      discover("user-2"),
      discover("user-3"),
    ]);
    expect(responses.map((response) => response.status)).toEqual([503, 503, 503, 503]);
    expect(started).toBe(2);
    expect(aborted).toBe(2);
    expect(admission.activeCount).toBe(0);
  });

  test("aborts timed-out firewall work and admits recovery", async () => {
    const admission = new IrohFirewallAdmission(2);
    let started = 0;
    let aborted = false;
    let brokerCalls = 0;
    const firewall = {
      id: "iroh-test-rule",
      timeoutMs: 5,
      admission,
      check: (_id: string, options?: unknown) => {
        started += 1;
        if (started > 1) return Promise.resolve({ rateLimited: false });
        const signal = (options as { signal?: AbortSignal } | undefined)?.signal;
        return new Promise<never>((_resolve, reject) => {
          signal?.addEventListener("abort", () => {
            aborted = true;
            reject(signal.reason);
          }, { once: true });
        });
      },
    };
    const discover = () => handleIrohRoute(
      new Request("https://cmux.test/api/devices/iroh"),
      "discover",
      {
        verify: async () => USER,
        broker: broker({
          discover: () => {
            brokerCalls += 1;
            return Effect.succeed({ bindings: [] });
          },
        }),
        firewall,
      },
    );

    expect((await discover()).status).toBe(503);
    expect(aborted).toBe(true);
    expect((await discover()).status).toBe(200);
    expect(started).toBe(2);
    expect(brokerCalls).toBe(1);
    expect(admission.activeCount).toBe(0);
  });

  test("partitions registration firewall limits by physical device and app instance", async () => {
    const keys: string[] = [];
    const firewall = {
      id: "iroh-test-rule",
      check: async (_id: string, options: { rateLimitKey: string }) => {
        keys.push(options.rateLimitKey);
        return { rateLimited: false };
      },
    };
    const deviceId = "10000000-0000-4000-8000-000000000001";
    const otherDeviceId = "10000000-0000-4000-8000-000000000002";
    const appInstanceId = "20000000-0000-4000-8000-000000000001";
    const otherAppInstanceId = "20000000-0000-4000-8000-000000000002";
    const challenge = (device: string, instance: string) => handleIrohRoute(
      authedPost("/api/devices/iroh/challenge", {
        deviceId: device,
        appInstanceId: instance,
      }),
      "challenge",
      {
        verify: async () => USER,
        broker: broker({ issueChallenge: () => Effect.succeed({}) }),
        firewall,
      },
    );
    const register = (device: string, instance: string) => handleIrohRoute(
      authedPost("/api/devices/iroh/register", {
        payload: Buffer.from(JSON.stringify({
          deviceId: device,
          appInstanceId: instance,
        })).toString("base64url"),
      }),
      "register",
      {
        verify: async () => USER,
        broker: broker({ register: () => Effect.succeed({}) }),
        firewall,
      },
    );

    expect((await challenge(deviceId, appInstanceId)).status).toBe(201);
    expect((await challenge(deviceId, appInstanceId)).status).toBe(201);
    expect((await challenge(deviceId, otherAppInstanceId)).status).toBe(201);
    expect((await challenge(otherDeviceId, appInstanceId)).status).toBe(201);
    expect((await register(deviceId, appInstanceId)).status).toBe(201);
    expect((await register(deviceId, otherAppInstanceId)).status).toBe(201);

    expect(keys[0]).toBe(keys[1]);
    expect(keys[0]).not.toBe(keys[2]);
    expect(keys[0]).not.toBe(keys[3]);
    expect(keys[4]).not.toBe(keys[5]);
  });

  test("keeps malformed registration identities in the account fallback partition", async () => {
    const keys: string[] = [];
    const firewall = {
      id: "iroh-test-rule",
      check: async (_id: string, options: { rateLimitKey: string }) => {
        keys.push(options.rateLimitKey);
        return { rateLimited: false };
      },
    };
    const send = (deviceId: string, appInstanceId: string) => handleIrohRoute(
      authedPost("/api/devices/iroh/challenge", { deviceId, appInstanceId }),
      "challenge",
      {
        verify: async () => USER,
        broker: broker({ issueChallenge: () => Effect.succeed({}) }),
        firewall,
      },
    );

    expect((await send("invalid-device-a", "invalid-instance-a")).status).toBe(201);
    expect((await send("invalid-device-b", "invalid-instance-b")).status).toBe(201);
    expect(keys).toHaveLength(2);
    expect(keys[0]).toBe(keys[1]);
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
