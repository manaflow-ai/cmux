import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { Database } from "../db/effect";
import { cloudDb, closeCloudDbForTests } from "../db/client";
import { closePublicationAuthDb, publicationDatabaseRuntime } from "../services/vm-publications/database";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
const originalMax = process.env.CMUX_DB_POOL_MAX;
beforeAll(() => { process.env.CMUX_DB_POOL_MAX = "1"; });
afterAll(async () => {
  await closeCloudDbForTests();
  await closePublicationAuthDb();
  if (originalMax === undefined) delete process.env.CMUX_DB_POOL_MAX;
  else process.env.CMUX_DB_POOL_MAX = originalMax;
});

describe("publication authorization capacity", () => {
  dbTest("authorization can run while the shared one-connection pool is occupied", async () => {
    let release!: () => void;
    let acquired!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    const ready = new Promise<void>(resolve => { acquired = resolve; });
    const background = cloudDb().transaction(async tx => {
      await tx.execute(sql`select 1`);
      acquired();
      await held;
    });
    await ready;
    try {
      const runtime = await publicationDatabaseRuntime();
      const completed = await runtime.runPromise(
        Effect.flatMap(Database, db => db.execute(sql`select 1`)).pipe(
          Effect.as(true),
          Effect.timeout("1 second"),
        ),
      );
      expect(completed).toBe(true);
    } finally {
      release();
      await background;
    }
  });
});
