import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

// Stack user in two teams ("team-a" default-selected, plus "team-b"), so the
// multi-team registration path can be exercised. `currentUserId` is switchable
// so a test can impersonate a second member of the same team.
let currentUserId = "registry-user-1";
const getUser = mock(async () => ({
  id: currentUserId,
  displayName: null,
  primaryEmail: `${currentUserId}@example.com`,
  selectedTeam: { id: "team-a" },
  listTeams: async () => [{ id: "team-a" }, { id: "team-b" }],
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

const { DELETE, GET, POST } = await import("../app/api/devices/route");

let sql: Sql | null = null;

const DEVICE_A = "11111111-1111-4111-8111-111111111111";
const DEVICE_B = "22222222-2222-4222-8222-222222222222";

function authHeaders(teamId?: string): Record<string, string> {
  const base: Record<string, string> = {
    authorization: "Bearer access-token",
    "x-stack-refresh-token": "refresh-token",
    "content-type": "application/json",
  };
  if (teamId) base["x-cmux-team-id"] = teamId;
  return base;
}

function registerRequest(body: Record<string, unknown>, teamId?: string): Request {
  return new Request("https://cmux.test/api/devices", {
    method: "POST",
    headers: authHeaders(teamId),
    body: JSON.stringify(body),
  });
}

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate devices, device_app_instances restart identity cascade`;
  getUser.mockClear();
  currentUserId = "registry-user-1";
});

describe("device registry route", () => {
  dbTest("registers a Mac and its app instance, then lists it for the team", async () => {
    if (!sql) throw new Error("test database not initialized");

    const register = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "Lawrence's Mac",
        tag: "stable",
        routes: [{ id: "r1", kind: "tailscale", priority: 0, endpoint: { host: "100.1.2.3", port: 51001 } }],
      }),
    );
    expect(register.status).toBe(200);

    const listResponse = await GET(
      new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }),
    );
    expect(listResponse.status).toBe(200);
    const list = (await listResponse.json()) as {
      teamId: string;
      devices: Array<{
        deviceId: string;
        displayName: string | null;
        platform: string;
        instances: Array<{ tag: string; routes: unknown[] }>;
      }>;
    };
    expect(list.teamId).toBe("team-a");
    expect(list.devices).toHaveLength(1);
    expect(list.devices[0].deviceId).toBe(DEVICE_A);
    expect(list.devices[0].displayName).toBe("Lawrence's Mac");
    expect(list.devices[0].instances).toHaveLength(1);
    expect(list.devices[0].instances[0].tag).toBe("stable");
    expect(list.devices[0].instances[0].routes).toHaveLength(1);
  });

  dbTest("re-registering the same (device, tag) refreshes routes in place (auto-pair path)", async () => {
    if (!sql) throw new Error("test database not initialized");

    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        tag: "stable",
        routes: [{ id: "old", kind: "tailscale", priority: 0, endpoint: { host: "100.0.0.1", port: 1 } }],
      }),
    );
    // Mac moved networks / restarted on a new port: re-register with fresh routes.
    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        tag: "stable",
        routes: [{ id: "new", kind: "tailscale", priority: 0, endpoint: { host: "100.9.9.9", port: 51999 } }],
      }),
    );

    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A})
    `;
    expect(total).toBe(1);

    const list = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }))
    ).json()) as { devices: Array<{ instances: Array<{ routes: Array<{ endpoint: { host: string } }> }> }> };
    expect(list.devices[0].instances[0].routes[0].endpoint.host).toBe("100.9.9.9");
  });

  dbTest("caps app instances per device when the tag varies", async () => {
    if (!sql) throw new Error("test database not initialized");

    // Register one device under 25 distinct tags (the cap), then a 26th.
    const statuses: number[] = [];
    for (let i = 0; i < 26; i++) {
      const response = await POST(
        registerRequest({
          deviceId: DEVICE_A,
          platform: "mac",
          tag: `tag-${i}`,
          routes: [],
        }),
      );
      statuses.push(response.status);
    }
    // First 25 succeed, the 26th distinct tag is rejected.
    expect(statuses.slice(0, 25).every((s) => s === 200)).toBe(true);
    expect(statuses[25]).toBe(429);

    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A})
    `;
    expect(total).toBe(25);

    // Re-registering an existing tag is an update, not a new row, so it is not
    // capped even at the limit.
    const reRegister = await POST(
      registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "tag-0", routes: [] }),
    );
    expect(reRegister.status).toBe(200);
  });

  dbTest("drops structurally invalid route entries on register", async () => {
    if (!sql) throw new Error("test database not initialized");

    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        tag: "stable",
        // Mix of valid objects and junk (string, number, null, nested array).
        routes: [
          { id: "r1", kind: "tailscale", endpoint: { type: "host_port", host: "100.1.1.1", port: 1 } },
          "not-a-route",
          42,
          null,
          ["nested"],
          { id: "r2", kind: "tailscale", endpoint: { type: "host_port", host: "100.2.2.2", port: 2 } },
        ],
      }),
    );

    const [{ routes }] = await sql<{ routes: unknown[] }[]>`
      select routes from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A}) and tag = 'stable'
    `;
    // Only the two object entries are stored; scalars/arrays are dropped.
    expect(Array.isArray(routes)).toBe(true);
    expect(routes).toHaveLength(2);
  });

  dbTest("registers the same device UUID in two teams the user belongs to", async () => {
    if (!sql) throw new Error("test database not initialized");

    // Same physical Mac (same cmux UUID), registered under team-a then team-b.
    const inA = await POST(
      registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "stable", routes: [] }, "team-a"),
    );
    const inB = await POST(
      registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "stable", routes: [] }, "team-b"),
    );
    expect(inA.status).toBe(200);
    expect(inB.status).toBe(200);

    // Two distinct per-team rows for the one device UUID.
    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from devices where device_uuid = ${DEVICE_A}
    `;
    expect(total).toBe(2);

    // Each team only sees its own row for the device.
    const listA = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders("team-a") }))
    ).json()) as { teamId: string; devices: Array<{ deviceId: string }> };
    expect(listA.teamId).toBe("team-a");
    expect(listA.devices.map((d) => d.deviceId)).toEqual([DEVICE_A]);
  });

  dbTest("only the registering user may overwrite a device's routes", async () => {
    if (!sql) throw new Error("test database not initialized");

    // User 1 registers their Mac with their own routes.
    const ownRoutes = [
      { id: "own", kind: "tailscale", priority: 0, endpoint: { type: "host_port", host: "100.1.1.1", port: 51001 } },
    ];
    expect(
      (await POST(registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "stable", routes: ownRoutes }))).status,
    ).toBe(200);

    // A second member of the same team tries to overwrite those routes with
    // their own host (a redirect attack). It must be rejected, routes untouched.
    currentUserId = "registry-user-2";
    const attack = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        tag: "stable",
        routes: [
          { id: "evil", kind: "tailscale", priority: 0, endpoint: { type: "host_port", host: "100.6.6.6", port: 51666 } },
        ],
      }),
    );
    expect(attack.status).toBe(403);

    const [{ routes }] = await sql<{ routes: Array<{ endpoint: { host: string } }> }[]>`
      select routes from device_app_instances
      where device_id in (select id from devices where device_uuid = ${DEVICE_A}) and tag = 'stable'
    `;
    expect(routes[0].endpoint.host).toBe("100.1.1.1");

    // The owner can still update their own device.
    currentUserId = "registry-user-1";
    const reRegister = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        tag: "stable",
        routes: [
          { id: "own2", kind: "tailscale", priority: 0, endpoint: { type: "host_port", host: "100.9.9.9", port: 51999 } },
        ],
      }),
    );
    expect(reRegister.status).toBe(200);
  });

  dbTest("rejects a team the caller is not a member of", async () => {
    if (!sql) throw new Error("test database not initialized");

    const response = await POST(
      registerRequest(
        { deviceId: DEVICE_A, platform: "mac", routes: [] },
        "team-not-mine",
      ),
    );
    expect(response.status).toBe(403);

    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(0);
  });

  dbTest("delete removes the device and cascades its instances", async () => {
    if (!sql) throw new Error("test database not initialized");

    await POST(registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "stable", routes: [] }));
    await POST(registerRequest({ deviceId: DEVICE_B, platform: "mac", tag: "stable", routes: [] }));

    const del = await DELETE(
      new Request("https://cmux.test/api/devices", {
        method: "DELETE",
        headers: authHeaders(),
        body: JSON.stringify({ deviceId: DEVICE_A }),
      }),
    );
    expect(del.status).toBe(200);

    const [{ devicesTotal }] = await sql<{ devicesTotal: number }[]>`
      select count(*)::int as "devicesTotal" from devices
    `;
    expect(devicesTotal).toBe(1);
    const [{ instancesTotal }] = await sql<{ instancesTotal: number }[]>`
      select count(*)::int as "instancesTotal" from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A})
    `;
    expect(instancesTotal).toBe(0);
  });

  dbTest("a non-owner cannot delete another user's device", async () => {
    if (!sql) throw new Error("test database not initialized");

    // User 1 registers their Mac.
    await POST(registerRequest({ deviceId: DEVICE_A, platform: "mac", tag: "stable", routes: [] }));

    // A second same-team member tries to delete it: the row must survive.
    currentUserId = "registry-user-2";
    const del = await DELETE(
      new Request("https://cmux.test/api/devices", {
        method: "DELETE",
        headers: authHeaders(),
        body: JSON.stringify({ deviceId: DEVICE_A }),
      }),
    );
    expect(del.status).toBe(200); // idempotent no-op, not an error

    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from devices where device_uuid = ${DEVICE_A}
    `;
    expect(total).toBe(1);
  });
});
