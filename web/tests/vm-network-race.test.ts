import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmRepository, VmRepositoryLive, type VmRepositoryShape } from "../services/vms/repository";

const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = process.env.CMUX_DB_TEST === "1" ? serialTest : test.skip;
let sql: Sql;
beforeAll(() => {
  if (process.env.CMUX_DB_TEST === "1") sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
});
afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

const runRepo = <T>(operation: (repo: VmRepositoryShape) => Effect.Effect<T, unknown>) =>
  Effect.runPromise(Effect.flatMap(VmRepository, operation).pipe(Effect.provide(VmRepositoryLive)));

describe("first-use VM network persistence", () => {
  dbTest("concurrent writers converge without confusing the two unique indexes", async () => {
    // Always use cold owners: a cached network bypasses the contested insert.
    for (let round = 0; round < 12; round++) {
      const owner = `network-race-${randomUUID()}`;
      const providerNetworkId = `net-${randomUUID()}`;
      try {
        const results = await Promise.allSettled(Array.from({ length: 16 }, () => runRepo(repo => repo.upsertNetwork!({
          userId: owner, provider: "freestyle", providerNetworkId, cidr: "10.40.0.0/24",
        }))));
        expect(results.filter(result => result.status === "rejected")).toEqual([]);
        const ids = results.flatMap(result => result.status === "fulfilled" ? [result.value.id] : []);
        expect(new Set(ids).size).toBe(1);
        const persisted = await runRepo(repo => repo.findNetwork!(owner, "freestyle"));
        expect(persisted?.id).toBe(ids[0]);

        // A conflict belonging to a different owner must still fail closed.
        const foreign = `${owner}-foreign`;
        const conflict = await runRepo(repo => repo.upsertNetwork!({
          userId: foreign, provider: "freestyle", providerNetworkId,
        }).pipe(Effect.either));
        expect(conflict._tag).toBe("Left");
        expect(await runRepo(repo => repo.findNetwork!(foreign, "freestyle"))).toBeNull();
      } finally {
        await sql`delete from cloud_vm_networks where provider_network_id = ${providerNetworkId}`;
      }
    }
  });
});
