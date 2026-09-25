import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { vmRepositoryLiveShape as repository } from "../services/vms/repository";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
let database: Sql;
const users: string[] = [];
const user = () => {
  const id = `welcome-${randomUUID()}`;
  users.push(id);
  return id;
};
const finish = (id: string) => Effect.runPromise(repository.markCreateRunning({
  id, providerVmId: `fixture-${id}`, image: "welcome-fixture",
}));
const create = async (userId: string, team = userId, key = randomUUID(), eligible = true, running = true) => {
  const result = await Effect.runPromise(repository.beginCreate({
    userId, billingTeamId: team, billingPlanId: "pro", provider: "freestyle",
    image: "welcome-fixture", maxActiveVms: null, idempotencyKey: key,
    welcomeOnFirstMachine: eligible,
  }));
  return result.inserted && running ? { ...result, vm: await finish(result.vm.id) } : result;
};

beforeAll(() => {
  if (process.env.CMUX_DB_TEST !== "1") return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("An isolated test DATABASE_URL is required");
  database = postgres(url, { max: 1 });
});

afterAll(async () => {
  if (database) {
    for (const id of users) {
      await database`delete from cloud_vm_bases where created_by_user_id = ${id}`;
      await database`delete from cloud_vms where user_id = ${id}`;
    }
    await database.end();
  }
  await closeCloudDbForTests();
});

describe("Cloud welcome first-user eligibility", () => {
  dbTest("Base and ordinary creates share one first-user grant; Base reset never rearms it", async () => {
    const id = user();
    const input = {
      userId: id, billingTeamId: id, billingPlanId: "pro", billingCustomerType: "user" as const,
      provider: "freestyle" as const, image: "welcome-fixture", maxActiveVms: null,
    };
    const base = await Effect.runPromise(repository.beginBaseOpen(input));
    const baseInput = {
      baseId: base.base.id, generation: base.generation.generation, vmId: base.vm.id,
      providerVmId: `fixture-${base.vm.id}`, image: input.image, userId: id,
    };
    const first = await Effect.runPromise(repository.markBaseCreateRunning(baseInput));
    expect(first.providerMetadata.cloudWelcomeEligible).toBe(true);
    expect((await Effect.runPromise(repository.markBaseCreateRunning(baseInput))).providerMetadata.cloudWelcomeEligible).toBe(true);
    expect((await create(id, `${id}-another-team`)).vm.providerMetadata.cloudWelcomeEligible).toBeUndefined();
    const reset = await Effect.runPromise(repository.beginBaseReset(input));
    const resetVm = await Effect.runPromise(repository.markBaseCreateRunning({
      ...baseInput, baseId: reset.base.id, generation: reset.generation.generation,
      vmId: reset.vm.id, providerVmId: `fixture-${reset.vm.id}`,
    }));
    expect(resetVm.providerMetadata.cloudWelcomeEligible).toBeUndefined();
  });

  dbTest("concurrent Base and ordinary successful finalizations grant exactly one machine", async () => {
    const id = user();
    const base = await Effect.runPromise(repository.beginBaseOpen({
      userId: id, billingTeamId: id, billingPlanId: "pro", billingCustomerType: "user",
      provider: "freestyle", image: "welcome-fixture", maxActiveVms: null,
    }));
    const ordinary = await create(id, `${id}-another-team`, randomUUID(), true, false);
    const finalized = await Promise.all([
      finish(ordinary.vm.id),
      Effect.runPromise(repository.markBaseCreateRunning({
        baseId: base.base.id, generation: base.generation.generation, vmId: base.vm.id,
        providerVmId: `fixture-${base.vm.id}`, image: "welcome-fixture", userId: id,
      })),
    ]);
    expect(finalized.filter(vm => vm.providerMetadata.cloudWelcomeEligible === true)).toHaveLength(1);
  });

  dbTest("concurrent creations across teams grant one machine and replay keeps its receipt", async () => {
    const id = user();
    const keys = [randomUUID(), randomUUID()];
    const rows = await Promise.all(keys.map((key, index) => create(id, `${id}-${index}`, key)));
    expect(rows.filter(({ vm }) => vm.providerMetadata.cloudWelcomeEligible === true)).toHaveLength(1);
    const index = rows.findIndex(({ vm }) => vm.providerMetadata.cloudWelcomeEligible === true);
    const replay = await create(id, `${id}-${index}`, keys[index]!);
    expect(replay.inserted).toBe(false);
    expect(replay.vm.id).toBe(rows[index]!.vm.id);
    expect(replay.vm.providerMetadata.cloudWelcomeEligible).toBe(true);
  });

  dbTest("deletion, another team, and old unmarked machines never reset first use", async () => {
    const id = user();
    const first = await create(id, id, randomUUID(), false);
    await database`update cloud_vms set status = 'destroyed' where id = ${first.vm.id}`;
    const later = await create(id, `${id}-second-team`);
    expect(later.vm.providerMetadata.cloudWelcomeEligible).toBeUndefined();
  });

  dbTest("a failed provisioning attempt leaves eligibility for its successful retry", async () => {
    const id = user();
    const first = await create(id, id, randomUUID(), true, false);
    const queued = await create(id, `${id}-other-team`, randomUUID(), true, false);
    await Effect.runPromise(repository.markCreateFailed({ id: first.vm.id, code: "fixture", message: "not delivered" }));
    const retry = await finish(queued.vm.id);
    expect(retry.providerMetadata.cloudWelcomeEligible).toBe(true);
    const later = await create(id);
    expect(later.vm.providerMetadata.cloudWelcomeEligible).toBeUndefined();
    expect((await finish(retry.id)).providerMetadata.cloudWelcomeEligible).toBe(true);
  });

  dbTest("users sharing a team each have their own first use", async () => {
    const one = user();
    const two = user();
    const rows = await Promise.all([create(one, one), create(two, one)]);
    expect(rows.every(({ vm }) => vm.providerMetadata.cloudWelcomeEligible === true)).toBe(true);
  });
});
