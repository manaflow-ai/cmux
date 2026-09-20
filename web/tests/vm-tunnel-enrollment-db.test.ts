import { randomUUID } from "node:crypto";
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
  const databaseURL = process.env.CMUX_DB_TEST_DATABASE_URL;
  if (!databaseURL) {
    throw new Error("CMUX_DB_TEST_DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  const configuredURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (configuredURL !== databaseURL) {
    throw new Error("Cloud DB configuration must use CMUX_DB_TEST_DATABASE_URL in DB tests");
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

    const testID = randomUUID();
    const userId = `test-tunnel-lock-user-${testID}`;
    const deviceFingerprint = `test-tunnel-lock-device-${testID}`;
    const expiresAt = new Date("9999-12-31T23:59:59.000Z");
    const acquire = (ownerToken: string) =>
      Effect.runPromise(
        Effect.gen(function* () {
          const repo = yield* VmRepository;
          return yield* repo.acquireTunnelEnrollmentLock!({
            userId,
            deviceFingerprint,
            ownerToken,
            expiresAt,
          });
        }).pipe(Effect.provide(VmRepositoryLive)),
      );

    try {
      await expect(acquire("owner-db-tunnel-lock-1")).resolves.toBe(true);
      await expect(acquire("owner-db-tunnel-lock-2")).resolves.toBe(false);
    } finally {
      await sql`
        delete from cloud_vm_tunnel_enrollment_locks
        where user_id = ${userId} and device_fingerprint = ${deviceFingerprint}
      `;
    }
  });
});
