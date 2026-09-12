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
    const query = (async () => {
      const runtime = await publicationDatabaseRuntime();
      return runtime.runPromise(Effect.flatMap(Database, db => db.execute(sql`select 1`)));
    })();
    let queryFailed = false;
    let queryError: unknown;
    let queryTimedOut = false;
    let timeoutID: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        query,
        new Promise<never>((_, reject) => {
          timeoutID = setTimeout(() => {
            queryTimedOut = true;
            reject(new Error("publication auth query did not complete while the cloud pool was held"));
          }, 5_000);
        }),
      ]);
    } catch (error) {
      queryFailed = true;
      queryError = error;
    } finally {
      if (timeoutID !== undefined) clearTimeout(timeoutID);
      release();
      await background;
    }
    if (queryFailed) {
      // Drain the query after releasing the held connection so a deliberately
      // shared pool fails quickly without leaving a rejected promise behind.
      await query.catch(() => undefined);
      if (queryTimedOut) {
        throw new Error("publication auth query blocked behind the cloud pool connection");
      }
      throw queryError;
    }
  });
});
