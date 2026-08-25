import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  makeConnectivityAuthority,
} from "../services/connectivity/authority";
import {
  handleConnectivitySync,
  handleScopedConnectivitySync,
} from "../services/connectivity/routeHandler";
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

const scope = {
  localBinding: {
    deviceId: "123e4567-e89b-42d3-a456-426614174000",
    appInstanceId: "223e4567-e89b-42d3-a456-426614174000",
    tag: "stable",
    platform: "ios" as const,
  },
  peerBindings: {
    platform: "mac" as const,
    tags: ["default", "nightly"],
    pairingEnabled: true,
  },
};

const scopeWire = {
  local_binding: {
    device_id: scope.localBinding.deviceId,
    app_instance_id: scope.localBinding.appInstanceId,
    tag: scope.localBinding.tag,
    platform: scope.localBinding.platform,
  },
  peer_bindings: {
    platform: scope.peerBindings.platform,
    tags: scope.peerBindings.tags,
    pairing_enabled: true,
  },
};

function snapshotBroker() {
  return {
    discoverComplete: () => Effect.succeed(snapshot),
    discoverScoped: () => Effect.succeed(snapshot),
  };
}

describe("Connectivity authority", () => {
  test("returns a complete snapshot on initial sync", async () => {
    const authority = makeConnectivityAuthority(snapshotBroker());

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
      snapshot_complete: true,
    });
  });

  test("uses one broker-owned complete discovery snapshot", async () => {
    const bindings = Array.from({ length: 300 }, (_, index) => ({
      binding_id: `binding-${index + 1}`,
    }));
    let paginatedCalls = 0;
    let completeCalls = 0;
    const broker = {
      discover: () => {
        paginatedCalls += 1;
        return Effect.succeed({
          ...snapshot,
          bindings: bindings.slice(0, 128),
          next_cursor: "page-2",
        });
      },
      discoverComplete: () => {
        completeCalls += 1;
        return Effect.succeed({ ...snapshot, bindings });
      },
      discoverScoped: () => Effect.succeed({ ...snapshot, bindings }),
    };
    const authority = makeConnectivityAuthority(broker);

    const response = await Effect.runPromise(authority.sync("user-a", {
      protocol_version: 2,
      known_revision: null,
    }));

    expect((response.snapshot?.bindings as unknown[])).toHaveLength(300);
    expect(response).toMatchObject({ snapshot_complete: true });
    expect(paginatedCalls).toBe(0);
    expect(completeCalls).toBe(1);
  });

  test("omits an unchanged snapshot and identifies backend revision reset", async () => {
    const authority = makeConnectivityAuthority(snapshotBroker());

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
      snapshot_complete: true,
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
        syncScoped: () => Effect.die(new Error("unexpected scoped sync")),
      },
    });

    expect(response.status).toBe(401);
    expect(called).toBe(false);
  });

  test("serves an authenticated no-store sync response", async () => {
    const authority = makeConnectivityAuthority(snapshotBroker());
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
      discoverComplete: () => {
        calls += 1;
        return Effect.succeed(snapshot);
      },
      discoverScoped: () => Effect.succeed(snapshot),
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

  test("returns completeness only for the echoed v3 discovery scope", async () => {
    let receivedScope: unknown;
    const authority = makeConnectivityAuthority({
      discoverComplete: () => Effect.succeed(snapshot),
      discoverScoped: (_userId, requestedScope) => {
        receivedScope = requestedScope;
        return Effect.succeed(snapshot);
      },
    });

    const response = await Effect.runPromise(authority.syncScoped("user-a", {
      protocol_version: 3,
      known_revision: null,
      discovery_scope: scopeWire,
    }));

    expect(receivedScope).toEqual(scope);
    expect(response).toEqual({
      protocol_version: 3,
      revision: 7,
      changed: true,
      reset: false,
      discovery_scope: scopeWire,
      snapshot,
      snapshot_scope_complete: true,
    });
    expect("snapshot_complete" in response).toBe(false);
  });

  test("serves authenticated v3 sync and rejects malformed scopes", async () => {
    const authority = makeConnectivityAuthority(snapshotBroker());
    const response = await handleScopedConnectivitySync(
      scopedSyncRequest(scopeWire),
      { verify: async () => USER, authority },
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toMatchObject({
      protocol_version: 3,
      discovery_scope: scopeWire,
      snapshot_scope_complete: true,
    });

    const malformed = await handleScopedConnectivitySync(scopedSyncRequest({
      ...scopeWire,
      peer_bindings: {
        ...scopeWire.peer_bindings,
        platform: "ios",
      },
    }), { verify: async () => USER, authority });
    expect(malformed.status).toBe(400);
    expect(await malformed.json()).toEqual({ error: "invalid_discovery_scope" });
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

function scopedSyncRequest(discoveryScope: unknown): Request {
  return new Request("https://cmux.test/api/connectivity/v3/sync", {
    method: "POST",
    headers: {
      authorization: "Bearer test-access",
      "x-stack-refresh-token": "test-refresh",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      protocol_version: 3,
      known_revision: null,
      discovery_scope: discoveryScope,
    }),
  });
}
