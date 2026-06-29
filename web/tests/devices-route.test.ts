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
  stackServerApp: { getUser },
}));

const { DELETE, GET, POST } = await import("../app/api/devices/route");
const { hostIsLoopback, hostIsTailscaleAttachable, manualRoutesAreValid } = await import(
  "../app/api/devices/route-classification"
);

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
    expect((await del.json()).deleted).toBe(1);

    // Deleting an unknown deviceId is an idempotent no-op, but `deleted` is 0 so
    // the CLI can report "not found" instead of a false success.
    const noop = await DELETE(
      new Request("https://cmux.test/api/devices", {
        method: "DELETE",
        headers: authHeaders(),
        body: JSON.stringify({ deviceId: "99999999-9999-4999-8999-999999999999" }),
      }),
    );
    expect(noop.status).toBe(200);
    expect((await noop.json()).deleted).toBe(0);

    const [{ devicesTotal }] = await sql<{ devicesTotal: number }[]>`
      select count(*)::int as "devicesTotal" from devices
    `;
    expect(devicesTotal).toBe(1);
    const [{ instancesTotal }] = await sql<{ instancesTotal: number }[]>`
      select count(*)::int as "instancesTotal" from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A})
    `;
    expect(instancesTotal).toBe(0);
  });

  // --- Manual remotes (cmux remotes add) ---

  test("hostIsLoopback classifies loopback and reachable hosts", () => {
    // Loopback in every spelling a phone could be tricked into dialing itself.
    for (const host of [
      "localhost",
      "localhost.",
      "sub.localhost",
      "127.0.0.1",
      "127.1",
      "127.0.0.255",
      "0.0.0.0",
      "::1",
      "::",
      "[::1]",
      "::ffff:127.0.0.1",
      "::ffff:7f00:1",
    ]) {
      expect(hostIsLoopback(host)).toBe(true);
    }
    // Reachable Tailscale / LAN / public hosts.
    for (const host of [
      "100.64.1.2",
      "192.168.1.50",
      "10.0.0.5",
      "8.8.8.8",
      "my-mac.tailnet.ts.net",
      "example.com",
      "fd7a:115c:a1e0::1",
    ]) {
      expect(hostIsLoopback(host)).toBe(false);
    }
  });

  test("hostIsTailscaleAttachable accepts only CGNAT and *.ts.net", () => {
    for (const host of [
      "100.64.0.1",
      "100.127.255.255",
      "100.100.5.7",
      "my-mac.tailnet.ts.net",
      "MY-MAC.TS.NET",
    ]) {
      expect(hostIsTailscaleAttachable(host)).toBe(true);
    }
    for (const host of [
      "192.168.1.5",
      "10.0.0.5",
      "172.16.0.1",
      "100.63.0.1",
      "100.128.0.1",
      "8.8.8.8",
      "example.com",
      "my-mac.local",
      "fd7a:115c:a1e0::1",
      // Malformed .ts.net strings that pass a naive suffix check but are not
      // dialable bare hosts.
      "bad host.ts.net",
      "https://mac.ts.net",
      "mac.ts.net:51001",
      "mac_underscore.ts.net",
      "-leading.ts.net",
      ".ts.net",
      // Leading-zero octets: inet_aton would read these as octal, so they are
      // not canonical CGNAT and must not be accepted as Tailscale-safe.
      "0100.64.1.2",
      "100.064.1.2",
      "100.64.01.2",
    ]) {
      expect(hostIsTailscaleAttachable(host)).toBe(false);
    }
  });

  test("manualRoutesAreValid enforces the full attach-route schema", () => {
    const ok = (overrides: Record<string, unknown> = {}, ep: Record<string, unknown> = {}) => [
      {
        id: "m0",
        kind: "tailscale",
        endpoint: { type: "host_port", host: "100.64.1.2", port: 51001, ...ep },
        ...overrides,
      },
    ];
    // Valid: id present, tailscale host:port, attachable host, in-range port.
    expect(manualRoutesAreValid(ok())).toBe(true);
    expect(manualRoutesAreValid(ok({}, { host: "my-mac.ts.net", port: 1 }))).toBe(true);
    expect(manualRoutesAreValid(ok({ priority: 0 }))).toBe(true); // integer priority ok
    expect(manualRoutesAreValid(ok({ priority: 5 }))).toBe(true);
    expect(manualRoutesAreValid(ok({ priority: "0" }))).toBe(false); // string priority (iOS drops it)
    expect(manualRoutesAreValid(ok({ priority: 1.5 }))).toBe(false); // non-integer priority
    // Invalid cases.
    expect(manualRoutesAreValid([])).toBe(false); // empty
    expect(manualRoutesAreValid(ok({ id: undefined }))).toBe(false); // missing id (iOS requires it)
    expect(manualRoutesAreValid(ok({ id: "" }))).toBe(false); // empty id
    expect(manualRoutesAreValid(ok({}, { type: undefined }))).toBe(false); // missing endpoint.type (iOS requires it)
    expect(manualRoutesAreValid(ok({}, { port: 0 }))).toBe(false); // port 0
    expect(manualRoutesAreValid(ok({}, { port: 70000 }))).toBe(false); // port out of range
    expect(manualRoutesAreValid(ok({ kind: "iroh" }))).toBe(false); // wrong kind
    expect(manualRoutesAreValid(ok({}, { host: "192.168.1.5" }))).toBe(false); // non-attachable host
    expect(
      manualRoutesAreValid([{ id: "m0", kind: "tailscale", endpoint: { type: "url", url: "wss://x" } }]),
    ).toBe(false); // wrong endpoint type
  });

  dbTest("rejects a manual remote with empty or port-0 routes", async () => {
    if (!sql) throw new Error("test database not initialized");

    const empty = await POST(
      registerRequest({ deviceId: DEVICE_A, platform: "mac", manual: true, routes: [] }),
    );
    expect(empty.status).toBe(400);
    expect(((await empty.json()) as { error: string }).error).toBe("non_attachable_route_rejected");

    const badPort = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        manual: true,
        routes: [{ kind: "tailscale", endpoint: { type: "host_port", host: "100.64.1.2", port: 0 } }],
      }),
    );
    expect(badPort.status).toBe(400);

    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(0);
  });

  dbTest("rejects a manual remote with a non-Tailscale (LAN) route", async () => {
    if (!sql) throw new Error("test database not initialized");

    const response = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "lan-remote",
        manual: true,
        routes: [
          { id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "192.168.1.5", port: 51001 } },
        ],
      }),
    );
    expect(response.status).toBe(400);
    expect(((await response.json()) as { error: string }).error).toBe("non_attachable_route_rejected");

    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(0);
  });

  dbTest("a non-manual self-registration may still advertise a LAN route", async () => {
    if (!sql) throw new Error("test database not initialized");

    // The Mac's own self-registration (no `manual` flag) is not subject to the
    // Tailscale attachability guard; it advertises whatever live routes it has.
    const response = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        routes: [
          { id: "r0", kind: "tailscale", endpoint: { type: "host_port", host: "192.168.1.5", port: 51001 } },
        ],
      }),
    );
    expect(response.status).toBe(200);
  });

  dbTest("client-supplied labels.manual cannot spoof the manual marker", async () => {
    if (!sql) throw new Error("test database not initialized");

    // No top-level `manual`, but labels claim manual: the validation gate must
    // not be bypassed and the persisted marker must not be set from labels.
    const resp = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "spoof",
        labels: { manual: true },
        // A loopback route that WOULD be rejected on the manual path; since this
        // is treated as a self-registration (no top-level manual), it stores.
        routes: [{ id: "r0", kind: "debug_loopback", endpoint: { type: "host_port", host: "127.0.0.1", port: 51001 } }],
      }),
    );
    expect(resp.status).toBe(200); // not the manual path, so not rejected

    const list = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }))
    ).json()) as { devices: Array<{ deviceId: string; labels: Record<string, unknown> }> };
    const row = list.devices.find((d) => d.deviceId === DEVICE_A);
    // The spoofed labels.manual was stripped, so `cmux remotes` (which filters on
    // labels.manual === true) will NOT treat this self-registered row as manual.
    expect(row?.labels.manual ?? false).toBe(false);
  });

  dbTest("rejects a manual remote whose route is loopback", async () => {
    if (!sql) throw new Error("test database not initialized");

    const response = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "bad-remote",
        manual: true,
        routes: [
          { id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "127.0.0.1", port: 51001 } },
        ],
      }),
    );
    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("loopback_route_rejected");

    // Nothing was stored.
    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(0);
  });

  dbTest("rejects a manual remote with a debug_loopback kind route", async () => {
    if (!sql) throw new Error("test database not initialized");

    const response = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        manual: true,
        routes: [
          { id: "m0", kind: "debug_loopback", endpoint: { type: "host_port", host: "192.168.1.5", port: 51001 } },
        ],
      }),
    );
    expect(response.status).toBe(400);
    expect(((await response.json()) as { error: string }).error).toBe("loopback_route_rejected");
  });

  dbTest("accepts and lists a manual remote with a reachable route", async () => {
    if (!sql) throw new Error("test database not initialized");

    const add = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "my-studio",
        manual: true,
        routes: [
          { id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.64.1.2", port: 51001 } },
        ],
      }),
    );
    expect(add.status).toBe(200);

    const list = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }))
    ).json()) as {
      devices: Array<{
        deviceId: string;
        displayName: string | null;
        instances: Array<{ routes: Array<{ endpoint: { host: string; port: number } }> }>;
      }>;
    };
    expect(list.devices).toHaveLength(1);
    expect(list.devices[0].displayName).toBe("my-studio");
    expect(list.devices[0].instances[0].routes[0].endpoint.host).toBe("100.64.1.2");
    expect(list.devices[0].instances[0].routes[0].endpoint.port).toBe(51001);
  });

  dbTest("marks manual remotes with labels.manual; self-registration is unmarked", async () => {
    if (!sql) throw new Error("test database not initialized");

    // A manual remote (cmux remotes add) and a self-registered Mac.
    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "manual-remote",
        manual: true,
        routes: [{ id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.64.1.2", port: 51001 } }],
      }),
    );
    await POST(
      registerRequest({
        deviceId: DEVICE_B,
        platform: "mac",
        displayName: "self-registered",
        routes: [{ id: "r0", kind: "tailscale", endpoint: { type: "host_port", host: "192.168.1.5", port: 51001 } }],
      }),
    );

    const list = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }))
    ).json()) as {
      devices: Array<{ deviceId: string; labels: Record<string, unknown> }>;
    };
    const byId = new Map(list.devices.map((d) => [d.deviceId, d.labels]));
    // The CLI (RemotesClient.list) filters on `labels.manual === true`, so only
    // the manual remote is listed/removable by `cmux remotes`.
    expect(byId.get(DEVICE_A)?.manual).toBe(true);
    expect(byId.get(DEVICE_B)?.manual ?? false).toBe(false);
  });

  dbTest("re-adding the same manual remote updates its routes in place", async () => {
    if (!sql) throw new Error("test database not initialized");

    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "my-studio",
        manual: true,
        routes: [{ id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.64.1.2", port: 51001 } }],
      }),
    );
    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "my-studio",
        manual: true,
        routes: [{ id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.99.99.99", port: 52002 } }],
      }),
    );

    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from devices where device_uuid = ${DEVICE_A}
    `;
    expect(total).toBe(1);

    const list = (await (
      await GET(new Request("https://cmux.test/api/devices", { method: "GET", headers: authHeaders() }))
    ).json()) as { devices: Array<{ instances: Array<{ routes: Array<{ endpoint: { host: string } }> }> }> };
    expect(list.devices[0].instances[0].routes[0].endpoint.host).toBe("100.99.99.99");
  });

  dbTest("a non-owner cannot overwrite or delete a manual remote", async () => {
    if (!sql) throw new Error("test database not initialized");

    // User 1 adds a manual remote.
    await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "studio",
        manual: true,
        routes: [{ id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.64.1.2", port: 51001 } }],
      }),
    );

    // User 2 (same team) tries to redirect it, then delete it: both must fail.
    currentUserId = "registry-user-2";
    const overwrite = await POST(
      registerRequest({
        deviceId: DEVICE_A,
        platform: "mac",
        displayName: "studio",
        manual: true,
        // CGNAT host so it passes attachability validation and reaches the
        // ownership guard (the behavior under test).
        routes: [{ id: "m0", kind: "tailscale", endpoint: { type: "host_port", host: "100.66.6.6", port: 51666 } }],
      }),
    );
    expect(overwrite.status).toBe(403);

    await DELETE(
      new Request("https://cmux.test/api/devices", {
        method: "DELETE",
        headers: authHeaders(),
        body: JSON.stringify({ deviceId: DEVICE_A }),
      }),
    );
    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from devices where device_uuid = ${DEVICE_A}
    `;
    expect(total).toBe(1);

    // Routes are still the owner's.
    const [{ routes }] = await sql<{ routes: Array<{ endpoint: { host: string } }> }[]>`
      select routes from device_app_instances where device_id in (select id from devices where device_uuid = ${DEVICE_A})
    `;
    expect(routes[0].endpoint.host).toBe("100.64.1.2");
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
    // Nothing was deleted (owned by user 1), so `deleted` is 0: the CLI reports
    // not-found rather than a false success for another member's deviceId.
    expect((await del.json()).deleted).toBe(0);

    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from devices where device_uuid = ${DEVICE_A}
    `;
    expect(total).toBe(1);
  });
});
