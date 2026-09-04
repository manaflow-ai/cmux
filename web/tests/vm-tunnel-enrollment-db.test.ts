import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmRepository, VmRepositoryLive } from "../services/vms/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

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

describe("tunnel enrollment repository", () => {
  dbTest("acquires a lease with a timestamp conflict fence", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_tunnel_enrollment_locks`;

    const expiresAt = new Date(Date.now() + 60_000);
    const acquire = (ownerToken: string) =>
      Effect.runPromise(
        Effect.gen(function* () {
          const repo = yield* VmRepository;
          return yield* repo.acquireTunnelEnrollmentLock!({
            userId: "user-db-tunnel-lock",
            deviceFingerprint: "device-db-tunnel-lock",
            ownerToken,
            expiresAt,
          });
        }).pipe(Effect.provide(VmRepositoryLive)),
      );

    await expect(acquire("owner-db-tunnel-lock-1")).resolves.toBe(true);
    await expect(acquire("owner-db-tunnel-lock-2")).resolves.toBe(false);
  });
});
