import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmRepository, VmRepositoryLive } from "../services/vms/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const DAY_MS = 24 * 60 * 60 * 1000;

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(url, { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

async function seedMac(userId: string, deviceId: string): Promise<string> {
  const [grant] = await sql!`
    insert into cloud_vm_access_grants (user_id, device_id)
    values (${userId}, ${deviceId})
    returning id`;
  return grant!.id as string;
}

async function seedTunnel(input: {
  userId: string;
  networkId: string;
  accessGrantId: string;
  fingerprint: string;
  purpose?: "browser" | "terminal";
  activityDaysAgo: number;
  revoked?: boolean;
}): Promise<string> {
  const at = new Date(Date.now() - input.activityDaysAgo * DAY_MS);
  const [row] = await sql!`
    insert into cloud_vm_tunnels (
      user_id, network_id, access_grant_id, provider, provider_tunnel_id,
      device_fingerprint, tunnel_purpose, client_public_key,
      created_at, updated_at, last_config_issued_at, revoked_at
    ) values (
      ${input.userId}, ${input.networkId}, ${input.accessGrantId}, 'freestyle', ${`tun-${randomUUID()}`},
      ${input.fingerprint}, ${input.purpose ?? "browser"}, 'key',
      ${at}, ${at}, ${at}, ${input.revoked ? at : null}
    )
    returning id`;
  return row!.id as string;
}

describe("stale tunnel candidates", () => {
  dbTest("returns only stale tunnels a newer tunnel on the same Mac replaced", async () => {
    const userId = `user-reap-${randomUUID()}`;
    const [network] = await sql!`
      insert into cloud_vm_networks (user_id, provider, provider_network_id)
      values (${userId}, 'freestyle', ${`vpc-${randomUUID()}`})
      returning id`;
    const networkId = network!.id as string;
    try {
      const mac = await seedMac(userId, "mac-1");
      const lonelyMac = await seedMac(userId, "mac-2");
      const replaced = await seedTunnel({ userId, networkId, accessGrantId: mac, fingerprint: "old-build", activityDaysAgo: 60 });
      await seedTunnel({ userId, networkId, accessGrantId: mac, fingerprint: "new-build", activityDaysAgo: 2 });
      // Stale, but the only terminal tunnel on this Mac: nothing replaced it.
      await seedTunnel({ userId, networkId, accessGrantId: mac, fingerprint: "old-build", purpose: "terminal", activityDaysAgo: 60 });
      // Stale, but the only tunnel on its Mac: an idle Mac keeps working.
      await seedTunnel({ userId, networkId, accessGrantId: lonelyMac, fingerprint: "only-build", activityDaysAgo: 90 });
      // Replaced, but only recently idle.
      await seedTunnel({ userId, networkId, accessGrantId: lonelyMac, fingerprint: "recent", purpose: "terminal", activityDaysAgo: 10 });
      await seedTunnel({ userId, networkId, accessGrantId: lonelyMac, fingerprint: "recent-2", purpose: "terminal", activityDaysAgo: 1 });
      // Already revoked rows are never candidates, and never count as a replacement.
      await seedTunnel({ userId, networkId, accessGrantId: lonelyMac, fingerprint: "gone", activityDaysAgo: 1, revoked: true });

      const candidates = await Effect.runPromise(Effect.gen(function* () {
        const repo = yield* VmRepository;
        return yield* repo.listStaleTunnelCandidates!({
          inactiveBefore: new Date(Date.now() - 30 * DAY_MS),
          limit: 100,
        });
      }).pipe(Effect.provide(VmRepositoryLive)));

      expect(candidates.filter((row) => row.userId === userId).map((row) => row.id)).toEqual([replaced]);
    } finally {
      await sql!`delete from cloud_vm_networks where id = ${networkId}`;
      await sql!`delete from cloud_vm_access_grants where user_id = ${userId}`;
    }
  });
});
