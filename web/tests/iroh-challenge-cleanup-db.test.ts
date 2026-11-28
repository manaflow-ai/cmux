import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import { Pool } from "pg";
import { cleanupIrohChallenges } from "../scripts/cloud-vm/iroh-challenge-cleanup";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
const now = new Date("2026-09-10T20:00:00Z");
const device = randomUUID();
let pool: Pool;

beforeAll(() => {
  if (process.env.CMUX_DB_TEST !== "1") return;
  pool = new Pool({
    connectionString: process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL,
    application_name: "iroh-challenge-cleanup-test",
    max: 4,
  });
});
beforeEach(async () => {
  if (pool) await pool.query("truncate iroh_registration_challenges");
});
afterAll(async () => { await pool?.end(); });

async function seed(input: {
  user?: string; namespace?: string; tag?: string; at?: number;
  expired?: boolean; consumed?: boolean; id?: string; device?: string;
} = {}) {
  const id = input.id ?? randomUUID();
  await pool.query(`insert into iroh_registration_challenges (
    id, user_id, device_uuid, app_instance_id, client_namespace, tag,
    endpoint_id, identity_generation, payload_sha256, nonce_hash,
    created_at, expires_at, consumed_at
  ) values ($1, $2, $3, $4, $5, $6, $7, 1, $7, $8, $9, $10, $11)`, [
    id, input.user ?? "cleanup-user", input.device ?? device, randomUUID(),
    input.namespace ?? "legacy", input.tag ?? "stable", "a".repeat(64),
    randomUUID().replaceAll("-", "").repeat(2),
    new Date(now.getTime() + (input.at ?? -1_000)),
    new Date(now.getTime() + (input.expired ? -1 : 300_000)),
    input.consumed ? now : null,
  ]);
  return id;
}

dbTest("cleanup retains the latest pending challenge for every complete tuple", async () => {
  await seed({ at: -2_000 });
  const keep = [await seed()];
  for (const input of [
    { namespace: "dev.cmux.app.beta" },
    { namespace: "dev.cmux.app.internal" },
    { namespace: "mac:com.cmuxterm.app.nightly" },
    { tag: "nightly" }, { user: "another-user" }, { device: randomUUID() },
  ]) {
    await seed({ ...input, at: -2_000 });
    keep.push(await seed(input));
  }
  // Expired and consumed rows must never displace a usable challenge.
  for (let i = 0; i < 5; i++) await seed({ expired: true, at: i });
  await seed({ consumed: true, at: 10 });

  const audit = await Effect.runPromise(cleanupIrohChallenges(pool, { now }));
  expect(audit.applied).toBe(false);
  expect(audit.before.rows).toBe(20);
  expect((await pool.query("select count(*)::int as n from iroh_registration_challenges")).rows[0].n).toBe(20);

  const result = await Effect.runPromise(cleanupIrohChallenges(pool, { now, apply: true, batchSize: 2 }));
  expect(result.deleted).toEqual({ expired: 5, consumed: 1, superseded: 7 });
  expect(result.after).toMatchObject({ rows: 7, expired: 0, consumed: 0, duplicates: 0 });
  expect((await pool.query("select id from iroh_registration_challenges")).rows.map(r => r.id).sort()).toEqual(keep.sort());
  const repeated = await Effect.runPromise(cleanupIrohChallenges(pool, { now, apply: true }));
  expect(repeated.deleted).toEqual({ expired: 0, consumed: 0, superseded: 0 });
});

dbTest("cleanup resolves tied legacy timestamps deterministically", async () => {
  await seed({ id: "00000000-0000-4000-8000-000000000001" });
  const id = await seed({ id: "00000000-0000-4000-8000-000000000002" });
  await Effect.runPromise(cleanupIrohChallenges(pool, { now, apply: true }));
  expect((await pool.query("select id from iroh_registration_challenges")).rows).toEqual([{ id }]);
});

dbTest("cleanup reports incomplete when a registration holds an expired row, then resumes", async () => {
  const id = await seed({ expired: true });
  const registration = await pool.connect();
  try {
    await registration.query("begin");
    await registration.query("select id from iroh_registration_challenges where id = $1 for update", [id]);
    const result = await Effect.runPromiseExit(cleanupIrohChallenges(pool, { now, apply: true }));
    expect(result._tag).toBe("Failure");
    expect((await pool.query("select id from iroh_registration_challenges")).rows).toEqual([{ id }]);
  } finally {
    await registration.query("rollback");
    registration.release();
  }
  const completed = await Effect.runPromise(cleanupIrohChallenges(pool, { now, apply: true }));
  expect(completed.after).toMatchObject({ rows: 0, expired: 0, duplicates: 0 });
});

dbTest("cleanup waits for an issuer and retains the challenge it commits", async () => {
  await seed();
  const issuer = await pool.connect();
  await issuer.query("begin");
  await issuer.query("select pg_advisory_xact_lock(hashtextextended('iroh:challenge:cleanup-user', 0))");
  const cleanup = Effect.runPromise(cleanupIrohChallenges(pool, { now, apply: true }));
  let waiting = false;
  try {
    const deadline = Date.now() + 1_500;
    while (Date.now() < deadline) {
      const result = await pool.query(`select exists (
        select 1 from pg_stat_activity where application_name = 'iroh-challenge-cleanup-test'
        and wait_event = 'advisory'
      ) as waiting`);
      if (result.rows[0].waiting) { waiting = true; break; }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    expect(waiting).toBe(true);
    const id = randomUUID();
    await issuer.query(`insert into iroh_registration_challenges (
      id, user_id, device_uuid, app_instance_id, client_namespace, tag,
      endpoint_id, identity_generation, payload_sha256, nonce_hash, created_at, expires_at
    ) select $1, user_id, device_uuid, app_instance_id, client_namespace, tag,
      endpoint_id, identity_generation, payload_sha256, $2, created_at + interval '1 second', expires_at
      from iroh_registration_challenges limit 1`, [id, "f".repeat(64)]);
    await issuer.query("commit");
    await cleanup;
    expect((await pool.query("select id from iroh_registration_challenges")).rows).toEqual([{ id }]);
  } finally {
    await issuer.query("rollback");
    issuer.release();
    await cleanup.catch(() => {});
  }
});
