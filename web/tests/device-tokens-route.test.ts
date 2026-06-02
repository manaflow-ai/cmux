import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

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
}));

const { POST } = await import("../app/api/device-tokens/route");

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

describe("device token route", () => {
  dbTest("serializes registration cap enforcement per user", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate device_tokens restart identity cascade`;
    getUser.mockClear();

    const responses = await Promise.all(
      Array.from({ length: 12 }, (_, index) =>
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
    expect(statuses).toEqual([200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 429, 429]);

    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_tokens where user_id = 'push-user-1'
    `;
    expect(stored.total).toBe(10);
  });
});
