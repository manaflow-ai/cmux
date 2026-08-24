import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";
import {
  MAX_DEVICE_TOKENS_PER_ACCOUNT,
  MAX_DEVICE_TOKENS_PER_USER,
} from "../services/apns/routePolicy";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const DB_STRESS_TEST_TIMEOUT_MS = 30_000;

const getUser = mock(async () => ({
  id: "push-user-1",
  displayName: null,
  primaryEmail: "push@example.com",
  selectedTeam: null,
  listTeams: async () => [],
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { DELETE, POST } = await import("../app/api/device-tokens/route");
const { PUT: PUT_FILTERS } = await import("../app/api/device-tokens/filters/route");

let sql: Sql | null = null;

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
  await sql`truncate device_tokens, account_deletion_tombstones restart identity cascade`;
  getUser.mockClear();
});

describe("device token route", () => {
  test("rejects a bundle that does not match the authenticated app namespace", async () => {
    const response = await POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-app-namespace": "dev.cmux.app.demo",
        },
        body: JSON.stringify({
          deviceToken: "b".repeat(64),
          bundleId: "dev.cmux.app.internal",
          platform: "ios",
        }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({
      error: "client_namespace_mismatch",
    });
  });

  dbTest("allows a released legacy client to unregister its unique token", async () => {
    if (!sql) throw new Error("test database not initialized");
    const token = "b".repeat(64);
    await sql`
      insert into device_tokens (
        user_id,
        device_token,
        bundle_id,
        environment,
        platform
      ) values (
        'push-user-1',
        ${token},
        'dev.cmux.app.internal',
        'production',
        'ios'
      )
    `;

    const response = await DELETE(
      new Request("https://cmux.test/api/device-tokens", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: token,
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    const [remaining] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from device_tokens
      where user_id = 'push-user-1' and device_token = ${token}
    `;
    expect(remaining.total).toBe(0);
  });

  dbTest("legacy unregister fails closed when token bytes span app namespaces", async () => {
    if (!sql) throw new Error("test database not initialized");
    const token = "c".repeat(64);
    await sql`
      insert into device_tokens (
        user_id,
        device_token,
        bundle_id,
        environment,
        platform
      ) values
        (
          'push-user-1',
          ${token},
          'dev.cmux.app.internal',
          'production',
          'ios'
        ),
        (
          'push-user-1',
          ${token},
          'dev.cmux.app.demo',
          'production',
          'ios'
        )
    `;

    const response = await DELETE(
      new Request("https://cmux.test/api/device-tokens", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({ deviceToken: token }),
      }),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "ambiguous_legacy_device_token",
    });
    const [remaining] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from device_tokens
      where user_id = 'push-user-1' and device_token = ${token}
    `;
    expect(remaining.total).toBe(2);
  });

  dbTest("blocks registration while account deletion is in progress", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`
      insert into account_deletion_tombstones (user_id_hash, user_id, status)
      values (${accountDeletionUserHash("push-user-1")}, ${"push-user-1"}, 'pending')
    `;

    const response = await POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: "b".repeat(64),
          bundleId: "dev.cmux.ios.push1",
          platform: "ios",
        }),
      }),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "account_deletion_in_progress" });
    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens where user_id = 'push-user-1'
    `;
    expect(stored.total).toBe(0);
  });

  dbTest("allows registration after a pending account deletion lease expires", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`
      insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
      values (
        ${accountDeletionUserHash("push-user-1")},
        ${"push-user-1"},
        'pending',
        now() - interval '20 minutes'
      )
    `;

    const response = await POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: "b".repeat(64),
          bundleId: "dev.cmux.ios.push1",
          platform: "ios",
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ ok: true });
    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens where user_id = 'push-user-1'
    `;
    expect(stored.total).toBe(1);
  });

  dbTest("serializes the 200-device ceiling without evicting unproven-live tokens", async () => {
    if (!sql) throw new Error("test database not initialized");

    const responses = await Promise.all(
      Array.from({ length: 202 }, (_, index) =>
        POST(
          new Request("https://cmux.test/api/device-tokens", {
            method: "POST",
            headers: {
              authorization: "Bearer access-token",
              "x-stack-refresh-token": "refresh-token",
            },
            body: JSON.stringify({
              deviceToken: index.toString(16).padStart(64, "0"),
              bundleId: "dev.cmux.ios.push1",
              platform: "ios",
            }),
          }),
        )
      ),
    );

    const statuses = responses.map((response) => response.status).sort();
    expect(statuses.filter((status) => status === 200)).toHaveLength(200);
    expect(statuses.filter((status) => status === 429)).toHaveLength(2);

    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens where user_id = 'push-user-1'
    `;
    expect(stored.total).toBe(200);
  }, DB_STRESS_TEST_TIMEOUT_MS);

  dbTest("refreshes a known token at capacity but rejects a new 201st token without eviction", async () => {
    if (!sql) throw new Error("test database not initialized");

    const oldestToken = "0".repeat(64);
    for (let index = 0; index < 200; index += 1) {
      const token = index.toString(16).padStart(64, "0");
      await sql`
        insert into device_tokens (
          user_id,
          device_token,
          platform,
          bundle_id,
          environment,
          created_at,
          updated_at
        )
        values (
          'push-user-1',
          ${token},
          'ios',
          'dev.cmux.ios.push1',
          'sandbox',
          ${new Date(Date.UTC(2026, 0, 1, 0, 0, index))},
          ${new Date(Date.UTC(2026, 0, 1, 0, 0, index))}
        )
      `;
    }

    const headers = {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
    };
    const register = (deviceToken: string) => POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers,
        body: JSON.stringify({
          deviceToken,
          bundleId: "dev.cmux.ios.push1",
          platform: "ios",
        }),
      }),
    );

    const refresh = await register(oldestToken);
    expect(refresh.status).toBe(200);
    expect(await refresh.json()).toMatchObject({ ok: true });

    const newToken = "f".repeat(64);
    const overLimit = await register(newToken);
    expect(overLimit.status).toBe(429);
    expect(await overLimit.json()).toEqual({
      error: "too_many_devices",
      limit: 200,
      action: "disable_push_on_another_device",
    });
    const stored = await sql<{ device_token: string }[]>`
      select device_token from device_tokens
      where user_id = 'push-user-1'
      order by device_token
    `;
    expect(stored).toHaveLength(200);
    expect(stored.map((row) => row.device_token)).toContain(oldestToken);
    expect(stored.map((row) => row.device_token)).not.toContain(newToken);
  }, DB_STRESS_TEST_TIMEOUT_MS);

  dbTest("applies registration capacity independently per app namespace", async () => {
    if (!sql) throw new Error("test database not initialized");

    const register = (index: number, bundleId: string) =>
      POST(
        new Request("https://cmux.test/api/device-tokens", {
          method: "POST",
          headers: {
            authorization: "Bearer access-token",
            "x-stack-refresh-token": "refresh-token",
            "x-cmux-app-namespace": bundleId,
          },
          body: JSON.stringify({
            deviceToken: `${bundleId === "dev.cmux.app.demo" ? "d" : "e"}${index
              .toString(16)
              .padStart(63, "0")}`,
            bundleId,
            platform: "ios",
          }),
        }),
      );

    const responses = await Promise.all([
      ...Array.from({ length: 10 }, (_, index) =>
        register(index, "dev.cmux.app.demo")),
      ...Array.from({ length: 10 }, (_, index) =>
        register(index, "dev.cmux.app.internal")),
    ]);
    expect(responses.every((response) => response.status === 200)).toBe(true);
  });

  dbTest("bounds total registrations across arbitrary app namespaces", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`
      insert into device_tokens (
        user_id,
        device_token,
        bundle_id,
        environment,
        platform
      )
      select
        'push-user-1',
        lpad(to_hex(value), 64, '0'),
        'dev.cmux.ios.cap' || (value / 10)::text,
        'sandbox',
        'ios'
      from generate_series(0, ${MAX_DEVICE_TOKENS_PER_ACCOUNT - 1}) as series(value)
    `;

    const response = await POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-app-namespace": "dev.cmux.ios.overflow",
        },
        body: JSON.stringify({
          deviceToken: "f".repeat(64),
          bundleId: "dev.cmux.ios.overflow",
          platform: "ios",
        }),
      }),
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({
      error: "too_many_devices",
      limit: MAX_DEVICE_TOKENS_PER_USER,
      action: "disable_push_on_another_device",
    });
  });

  dbTest("canonicalizes token casing for register and delete", async () => {
    if (!sql) throw new Error("test database not initialized");

    const token = "a".repeat(64);
    const headers = {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "x-cmux-app-namespace": "dev.cmux.ios.push1",
    };
    const register = (deviceToken: string) =>
      POST(
        new Request("https://cmux.test/api/device-tokens", {
          method: "POST",
          headers,
          body: JSON.stringify({
            deviceToken,
            bundleId: "dev.cmux.ios.push1",
            platform: "ios",
          }),
        }),
      );

    expect((await register(token.toUpperCase())).status).toBe(200);
    expect((await register(token)).status).toBe(200);

    const [stored] = await sql<{ total: number; token: string }[]>`
      select count(*)::int as total, min(device_token) as token from device_tokens where user_id = 'push-user-1'
    `;
    expect(stored).toEqual({ total: 1, token });

    const deleteResponse = await DELETE(
      new Request("https://cmux.test/api/device-tokens", {
        method: "DELETE",
        headers,
        body: JSON.stringify({
          deviceToken: token.toUpperCase(),
          bundleId: "dev.cmux.ios.push1",
        }),
      }),
    );
    expect(deleteResponse.status).toBe(200);

    const [remaining] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens where user_id = 'push-user-1'
    `;
    expect(remaining.total).toBe(0);
  });

  dbTest("keeps identical token bytes isolated by app namespace", async () => {
    if (!sql) throw new Error("test database not initialized");
    const deviceToken = "b".repeat(64);
    const request = (
      method: "POST" | "DELETE",
      bundleId: string,
    ) =>
      new Request("https://cmux.test/api/device-tokens", {
        method,
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-app-namespace": bundleId,
        },
        body: JSON.stringify({
          deviceToken,
          bundleId,
          platform: "ios",
        }),
      });

    expect((await POST(request("POST", "dev.cmux.app.internal"))).status).toBe(200);
    expect((await POST(request("POST", "dev.cmux.app.beta"))).status).toBe(200);

    const rowsBeforeDelete = await sql<{
      bundle_id: string;
    }[]>`
      select bundle_id
      from device_tokens
      where user_id = 'push-user-1' and device_token = ${deviceToken}
      order by bundle_id
    `;
    expect(rowsBeforeDelete).toEqual([
      { bundle_id: "dev.cmux.app.beta" },
      { bundle_id: "dev.cmux.app.internal" },
    ]);

    expect((await DELETE(request("DELETE", "dev.cmux.app.internal"))).status).toBe(200);

    const rowsAfterDelete = await sql<{
      bundle_id: string;
    }[]>`
      select bundle_id
      from device_tokens
      where user_id = 'push-user-1' and device_token = ${deviceToken}
    `;
    expect(rowsAfterDelete).toEqual([
      { bundle_id: "dev.cmux.app.beta" },
    ]);
  });

  test("push filters PUT validates before touching the database", async () => {
    const put = (body: Record<string, unknown>) => PUT_FILTERS(
      new Request("https://cmux.test/api/device-tokens/filters", {
        method: "PUT",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify(body),
      }),
    );

    const badToken = await put({
      deviceToken: "not-hex",
      bundleId: "com.cmux.app",
      filters: null,
    });
    expect(badToken.status).toBe(400);
    expect(await badToken.json()).toEqual({ error: "invalid_device_token" });

    const badBundle = await put({
      deviceToken: "b".repeat(64),
      bundleId: "com.example.app",
      filters: null,
    });
    expect(badBundle.status).toBe(400);
    expect(await badBundle.json()).toEqual({ error: "invalid_bundle_id" });

    const badFilters = await put({
      deviceToken: "b".repeat(64),
      bundleId: "com.cmux.app",
      filters: { version: 1, rules: [{ id: "r", enabled: true }] },
    });
    expect(badFilters.status).toBe(400);
    expect(await badFilters.json()).toEqual({ error: "filter_rule_missing_criteria" });
  });

  dbTest("push filters PUT stores, replaces, and clears the device's rules", async () => {
    if (!sql) throw new Error("test database not initialized");
    const token = "b".repeat(64);
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'push-user-1', ${token}, 'ios', 'dev.cmux.app.internal', 'production'
      )
    `;
    const put = (filters: unknown) => PUT_FILTERS(
      new Request("https://cmux.test/api/device-tokens/filters", {
        method: "PUT",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: token.toUpperCase(),
          bundleId: "dev.cmux.app.internal",
          filters,
        }),
      }),
    );
    const storedFilters = async () => {
      const [row] = await sql!<{ push_filters: unknown }[]>`
        select push_filters from device_tokens
        where user_id = 'push-user-1' and device_token = ${token}
      `;
      return row.push_filters;
    };

    const stored = await put({
      version: 1,
      rules: [{ id: "rule-1", enabled: true, groupName: " Backend Work " }],
    });
    expect(stored.status).toBe(200);
    expect(await stored.json()).toEqual({ ok: true });
    // Persisted normalized (trimmed) so send-time matching sees clean rules.
    expect(await storedFilters()).toEqual({
      version: 1,
      rules: [{ id: "rule-1", enabled: true, groupName: "Backend Work" }],
    });

    const cleared = await put(null);
    expect(cleared.status).toBe(200);
    expect(await cleared.json()).toEqual({ ok: true });
    expect(await storedFilters()).toBeNull();

    const unknown = await PUT_FILTERS(
      new Request("https://cmux.test/api/device-tokens/filters", {
        method: "PUT",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: "f".repeat(64),
          bundleId: "dev.cmux.app.internal",
          filters: null,
        }),
      }),
    );
    expect(unknown.status).toBe(404);
    expect(await unknown.json()).toEqual({ error: "unknown_device_token" });
  });

  dbTest("push filters PUT respects an active delivery lease", async () => {
    if (!sql) throw new Error("test database not initialized");
    const token = "c".repeat(64);
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment,
        delivery_lease_until, delivery_lease_token
      ) values (
        'push-user-1', ${token}, 'ios', 'com.cmux.app', 'production',
        now() + interval '30 seconds',
        '00000000-0000-4000-8000-000000000003'
      )
    `;

    const response = await PUT_FILTERS(
      new Request("https://cmux.test/api/device-tokens/filters", {
        method: "PUT",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          deviceToken: token,
          bundleId: "com.cmux.app",
          filters: null,
        }),
      }),
    );

    expect(response.status).toBe(409);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await response.json()).toMatchObject({
      error: "push_delivery_in_progress",
    });
  });

  dbTest("does not transfer or delete a token during an active delivery", async () => {
    if (!sql) throw new Error("test database not initialized");

    const token = "c".repeat(64);
    const ownedToken = "d".repeat(64);
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment,
        delivery_lease_until, delivery_lease_token
      ) values (
        'previous-user', ${token}, 'ios', 'com.cmux.app', 'production',
        now() + interval '30 seconds',
        '00000000-0000-4000-8000-000000000001'
      )
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment,
        delivery_lease_until, delivery_lease_token
      ) values (
        'push-user-1', ${ownedToken}, 'ios', 'com.cmux.app', 'production',
        now() + interval '30 seconds',
        '00000000-0000-4000-8000-000000000002'
      )
    `;
    const headers = {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
    };

    const registration = await POST(
      new Request("https://cmux.test/api/device-tokens", {
        method: "POST",
        headers,
        body: JSON.stringify({
          deviceToken: token,
          bundleId: "com.cmux.app",
          platform: "ios",
        }),
      }),
    );
    const deletion = await DELETE(
      new Request("https://cmux.test/api/device-tokens", {
        method: "DELETE",
        headers,
        body: JSON.stringify({ deviceToken: ownedToken }),
      }),
    );

    expect(registration.status).toBe(409);
    expect(Number(registration.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await registration.json()).toMatchObject({
      error: "push_delivery_in_progress",
    });
    expect(deletion.status).toBe(409);
    expect(Number(deletion.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await deletion.json()).toMatchObject({
      error: "push_delivery_in_progress",
    });
    const [stored] = await sql<{
      userId: string;
      bundleId: string;
    }[]>`
      select user_id as "userId", bundle_id as "bundleId"
      from device_tokens where device_token = ${token}
    `;
    expect(stored).toEqual({
      userId: "previous-user",
      bundleId: "com.cmux.app",
    });
    const [owned] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens
      where user_id = 'push-user-1' and device_token = ${ownedToken}
    `;
    expect(owned.total).toBe(1);
  });
});
