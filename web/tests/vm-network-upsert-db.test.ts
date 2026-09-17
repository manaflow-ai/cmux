import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { vmRepositoryLiveShape } from "../services/vms/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const userPrefix = `network-upsert-test-${randomUUID()}`;
let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(url, { max: 1 });
});

afterAll(async () => {
  if (sql) {
    await sql`delete from cloud_vm_networks where user_id like ${`${userPrefix}%`}`;
    await sql.end();
  }
  await closeCloudDbForTests();
});

describe("private network repository concurrency", () => {
  dbTest("same-owner concurrent upserts converge across both unique indexes", async () => {
    const upsert = vmRepositoryLiveShape.upsertNetwork;
    if (!upsert || !sql) throw new Error("test database is not initialized");

    for (let iteration = 0; iteration < 12; iteration += 1) {
      const userId = `${userPrefix}-${iteration}`;
      const input = {
        userId,
        provider: "freestyle" as const,
        providerNetworkId: `provider-${userId}`,
        slug: userId,
        cidr: "10.40.0.0/24",
        cidrV6: "fd00:40::/64",
      };
      const results = await Promise.allSettled(
        Array.from({ length: 12 }, () => Effect.runPromise(upsert(input))),
      );
      expect(results.filter((result) => result.status === "rejected")).toEqual([]);
      const rows = await sql<{ id: string; user_id: string }[]>`
        select id, user_id from cloud_vm_networks where user_id = ${userId}
      `;
      expect(rows).toHaveLength(1);
      for (const result of results) {
        if (result.status !== "fulfilled") throw result.reason;
        expect(result.value.id).toBe(rows[0]!.id);
        expect(result.value.userId).toBe(userId);
      }
    }
  });

  dbTest("a provider network cannot be reassigned to another owner", async () => {
    const upsert = vmRepositoryLiveShape.upsertNetwork;
    if (!upsert || !sql) throw new Error("test database is not initialized");
    const userId = `${userPrefix}-owner`;
    const input = {
      userId,
      provider: "freestyle" as const,
      providerNetworkId: `provider-${userId}`,
    };
    const original = await Effect.runPromise(upsert(input));
    const results = await Promise.allSettled([
      Effect.runPromise(upsert({ ...input, userId: `${userPrefix}-other-owner` })),
    ]);
    expect(results[0]?.status).toBe("rejected");
    const rows = await sql<{ id: string; user_id: string }[]>`
      select id, user_id from cloud_vm_networks
      where provider = 'freestyle' and provider_network_id = ${input.providerNetworkId}
    `;
    expect(rows).toEqual([{ id: original.id, user_id: userId }]);
  });
});
