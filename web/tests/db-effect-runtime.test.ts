import { afterAll, describe, expect, test } from "bun:test";
import { sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import { Database, makeDatabaseRuntime } from "../db/effect";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const runtime = enabled ? makeDatabaseRuntime({
  url: Redacted.make(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!),
  maxConnections: 2,
  applicationName: "cmux-effect-runtime-test",
}) : undefined;

afterAll(async () => { await runtime?.dispose(); });

describe("shared Effect database runtime", () => {
  dbTest("reuses the same database service across concurrent request boundaries", async () => {
    const databases = await Promise.all(Array.from({ length: 12 }, () => runtime!.runPromise(Database)));
    for (const database of databases) expect(database).toBe(databases[0]);
    const values = await Promise.all(Array.from({ length: 12 }, () => runtime!.runPromise(Effect.gen(function* () {
      const db = yield* Database;
      const rows = yield* db.execute<{ value: number }>(sql`select 1 as value`);
      return rows[0]?.value;
    }))));
    expect(values).toEqual(Array.from({ length: 12 }, () => 1));
  });

  dbTest("rolls back a native Effect transaction when a typed failure occurs", async () => {
    const failure = { _tag: "RejectedTestChange" } as const;
    await runtime!.runPromise(Effect.gen(function* () {
      const db = yield* Database;
      // The outer transaction owns the temporary table. The nested transaction
      // must roll back its insert while keeping that outer transaction usable.
      yield* db.transaction(tx => Effect.gen(function* () {
        yield* tx.execute(sql`create temporary table effect_rollback_probe (value integer) on commit drop`);
        const result = yield* tx.transaction(nested => Effect.gen(function* () {
          yield* nested.execute(sql`insert into effect_rollback_probe values (1)`);
          return yield* Effect.fail(failure);
        })).pipe(Effect.either);
        expect(result._tag).toBe("Left");
        if (result._tag !== "Left") throw new Error("expected transaction rejection");
        expect(result.left).toMatchObject(failure);
        const rows = yield* tx.execute<{ count: number }>(sql`select count(*)::integer as count from effect_rollback_probe`);
        expect(rows[0]?.count).toBe(0);
      }));
    }));
  });
});
