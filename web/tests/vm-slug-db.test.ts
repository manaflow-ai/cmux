import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmRepository, VmRepositoryLive, VM_PROVIDER_STATUS_PROBE_LEASE_MS } from "../services/vms/repository";
import { VM_SLUG_PATTERN } from "../services/vms/vmNaming";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function beginCreate(input: { userId: string; billingTeamId: string; idempotencyKey: string }) {
  return Effect.runPromise(
    Effect.gen(function* () {
      const repo = yield* VmRepository;
      return yield* repo.beginCreate({
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: "pro",
        provider: "freestyle",
        image: "test-image",
        maxActiveVms: null,
        idempotencyKey: input.idempotencyKey,
      });
    }).pipe(Effect.provide(VmRepositoryLive)),
  );
}

function claimProbe(input: { id: string; providerVmId: string; token: string }) {
  return Effect.runPromise(
    Effect.gen(function* () {
      const repo = yield* VmRepository;
      if (!repo.claimProviderStatusProbe) throw new Error("probe claim is not implemented");
      return yield* repo.claimProviderStatusProbe(input);
    }).pipe(Effect.provide(VmRepositoryLive)),
  );
}

describe("cloud VM slugs", () => {
  dbTest("every create row gets a distinct three-word slug in its team", async () => {
    const team = `team-slug-${Date.now()}`;
    const first = await beginCreate({ userId: "user-slug-a", billingTeamId: team, idempotencyKey: `${team}-1` });
    const second = await beginCreate({ userId: "user-slug-a", billingTeamId: team, idempotencyKey: `${team}-2` });
    expect(first.inserted).toBe(true);
    expect(second.inserted).toBe(true);
    expect(first.vm.slug).toMatch(VM_SLUG_PATTERN);
    expect(second.vm.slug).toMatch(VM_SLUG_PATTERN);
    expect(first.vm.slug).not.toBe(second.vm.slug);

    // A same-key retry returns the existing row, so the name is stable.
    const replay = await beginCreate({ userId: "user-slug-a", billingTeamId: team, idempotencyKey: `${team}-1` });
    expect(replay.inserted).toBe(false);
    expect(replay.vm.slug).toBe(first.vm.slug);

    await sql!`delete from cloud_vms where billing_team_id = ${team}`;
  });

  dbTest("the live-row index rejects a duplicate name and frees it once the machine is gone", async () => {
    const team = `team-slug-index-${Date.now()}`;
    const insert = (status: string) =>
      sql!`insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, image_id, status, slug)
           values ('user-slug-b', ${team}, 'pro', 'freestyle', 'test-image', ${status}::vm_status, 'sleepy-teal-otter')`;
    await insert("running");
    let duplicate: unknown = null;
    try {
      await insert("provisioning");
    } catch (err) {
      duplicate = err;
    }
    expect(duplicate).toMatchObject({ code: "23505" });
    // Destroyed and failed rows keep their slug for the audit trail but do
    // not hold the name.
    await insert("destroyed");
    await insert("failed");
    await sql!`update cloud_vms set status = 'destroyed' where billing_team_id = ${team} and status = 'running'`;
    await insert("running");

    await sql!`delete from cloud_vms where billing_team_id = ${team}`;
  });

  dbTest("provider probes suppress duplicates and reclaim an expired fence", async () => {
    const id = crypto.randomUUID();
    const providerVmId = `provider-probe-${id}`;
    const team = `team-probe-${Date.now()}`;
    await sql!`insert into cloud_vms (id, user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status, slug, provider_status_checked_at, provider_status_probe_token)
      values (${id}, 'user-probe', ${team}, 'pro', 'freestyle', ${providerVmId}, 'test-image', 'running', ${`probe-cloud-vm-${id.replaceAll("-", "")}`}, now(), 'held')`;

    expect(await claimProbe({ id, providerVmId, token: "new-token" })).toBe(false);
    await sql!`update cloud_vms set provider_status_checked_at = now() - (${VM_PROVIDER_STATUS_PROBE_LEASE_MS + 1} * interval '1 millisecond') where id = ${id}`;
    expect(await claimProbe({ id, providerVmId, token: "new-token" })).toBe(true);

    const [row] = await sql!<{ token: string | null }[]>`select provider_status_probe_token as token from cloud_vms where id = ${id}`;
    expect(row?.token).toBe("new-token");
    await sql!`delete from cloud_vms where id = ${id}`;
  });
});
