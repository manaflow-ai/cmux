import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  makeConnectivityAuthority,
} from "../services/connectivity/authority";
import { handleConnectivitySync } from "../services/connectivity/routeHandler";
import type { AuthedUser } from "../services/vms/auth";

const USER: AuthedUser = {
  id: "connectivity-user",
  displayName: null,
  primaryEmail: null,
  billingCustomerType: "user",
  billingTeamId: "connectivity-user",
  selectedTeamId: null,
  teams: [],
  teamIds: [],
  userBillingPlanId: null,
  billingPlanId: null,
  resolveSubrouterPermissions: async () => ({
    use: false,
    manageAccounts: false,
  }),
};

const snapshot = {
  route_contract_version: 1 as const,
  revision: 7,
  bindings: [{ binding_id: "binding-a" }],
};

describe("Connectivity authority", () => {
  test("returns a complete snapshot on initial sync", async () => {
    const authority = makeConnectivityAuthority({
      discover: () => Effect.succeed(snapshot),
    });

    const response = await Effect.runPromise(authority.sync("user-a", {
      protocol_version: 2,
      known_revision: null,
    }));

    expect(response).toEqual({
      protocol_version: 2,
      revision: 7,
      changed: true,
      reset: false,
      snapshot,
    });
  });

  test("omits an unchanged snapshot and identifies backend revision reset", async () => {
    const authority = makeConnectivityAuthority({
      discover: () => Effect.succeed(snapshot),
    });

    expect(await Effect.runPromise(authority.sync("user-a", {
      protocol_version: 2,
      known_revision: 7,
    }))).toEqual({
      protocol_version: 2,
      revision: 7,
      changed: false,
      reset: false,
    });

    expect(await Effect.runPromise(authority.sync("user-a", {
      protocol_version: 2,
      known_revision: 8,
    }))).toEqual({
      protocol_version: 2,
      revision: 7,
      changed: true,
      reset: true,
      snapshot,
    });
  });

  test("requires bearer authentication before reading sync state", async () => {
    let called = false;
    const response = await handleConnectivitySync(syncRequest(null), {
      verify: async () => null,
      authority: {
        sync: () => {
          called = true;
          return Effect.succeed({
            protocol_version: 2,
            revision: 0,
            changed: false,
            reset: false,
          });
        },
      },
    });

    expect(response.status).toBe(401);
    expect(called).toBe(false);
  });

  test("serves an authenticated no-store sync response", async () => {
    const authority = makeConnectivityAuthority({
      discover: () => Effect.succeed(snapshot),
    });
    const response = await handleConnectivitySync(syncRequest(null), {
      verify: async () => USER,
      authority,
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toMatchObject({
      protocol_version: 2,
      revision: 7,
      changed: true,
    });
  });

  test("rejects malformed and oversized sync requests before authority work", async () => {
    let calls = 0;
    const authority = makeConnectivityAuthority({
      discover: () => {
        calls += 1;
        return Effect.succeed(snapshot);
      },
    });
    const malformed = await handleConnectivitySync(new Request(
      "https://cmux.test/api/connectivity/v2/sync",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ protocol_version: 1, known_revision: 0 }),
      },
    ), {
      verify: async () => USER,
      authority,
    });
    expect(malformed.status).toBe(400);

    const oversized = await handleConnectivitySync(new Request(
      "https://cmux.test/api/connectivity/v2/sync",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          protocol_version: 2,
          known_revision: 0,
          padding: "x".repeat(1_024),
        }),
      },
    ), {
      verify: async () => USER,
      authority,
    });
    expect(oversized.status).toBe(413);
    expect(calls).toBe(0);
  });
});

function syncRequest(knownRevision: number | null): Request {
  return new Request("https://cmux.test/api/connectivity/v2/sync", {
    method: "POST",
    headers: {
      authorization: "Bearer test-access",
      "x-stack-refresh-token": "test-refresh",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      protocol_version: 2,
      known_revision: knownRevision,
    }),
  });
}
