import { afterAll, beforeAll, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { autosizeTag, pickMachineSize } from "../services/vms/autosize";
import { listMeasuredRuns, tagMeasuredRun } from "../services/vms/autosizeRuns";
import { VmRepository, VmRepositoryLive } from "../services/vms/repository";
import { VM_RESOURCE_PEAK_KEY } from "../services/vms/resourceUsage";

// Auto-sizing's measured runs, against Postgres: a tagged VM's accepted
// samples keep its peaks, and the next pick of its repo and task kind reads
// them back as one run.

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const user = `autosize-${randomUUID()}`;
const ids = [randomUUID(), randomUUID()];
const repoKey = `github.com/test/${user}`;
let sql: Sql;

const run = <A>(program: Effect.Effect<A, unknown, VmRepository>) => Effect.runPromise(program.pipe(Effect.provide(VmRepositoryLive)));
const record = (id: string, receivedAt: number, usage: { cpuPercent?: number; memoryUsedMb?: number; diskUsedMb?: number }) =>
  run(Effect.gen(function* () {
    const repo = yield* VmRepository;
    return yield* repo.recordResourceUsage!({ id, providerVmId: `provider-${id}`, usage, receivedAt });
  }));

beforeAll(async () => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 2 });
  for (const id of ids) {
    await sql`insert into cloud_vms (id,user_id,provider,provider_vm_id,image_id,status,provider_metadata)
      values (${id},${user},'freestyle',${`provider-${id}`},'sh-test','running','{"networkId":"preserved"}'::jsonb)`;
  }
});

afterAll(async () => {
  if (!enabled || !sql) return;
  await sql`delete from cloud_vms where user_id = ${user}`;
  await closeCloudDbForTests();
  await sql.end();
});

dbTest("accepted samples keep the run's peaks and CPU mean", async () => {
  const id = ids[0]!;
  expect(await record(id, 1_000_000, { cpuPercent: 50, memoryUsedMb: 3000, diskUsedMb: 9000 })).toBe(true);
  // Inside the 15 s window: not accepted, so not a peak either.
  expect(await record(id, 1_005_000, { cpuPercent: 100, memoryUsedMb: 9999 })).toBe(false);
  expect(await record(id, 1_020_000, { cpuPercent: 25, memoryUsedMb: 7000, diskUsedMb: 8000 })).toBe(true);
  expect(await record(id, 1_040_000, { memoryUsedMb: 5000 })).toBe(true);
  const [row] = await sql`select provider_metadata from cloud_vms where id = ${id}`;
  expect(row!.provider_metadata.networkId).toBe("preserved");
  expect(row!.provider_metadata[VM_RESOURCE_PEAK_KEY]).toEqual({
    providerVmId: `provider-${id}`, memoryUsedMb: 7000, diskUsedMb: 9000, cpuPercentSum: 75, cpuSamples: 2,
  });
});

dbTest("a tagged run with peaks is read back by the next pick", async () => {
  const pick = pickMachineSize({ taskKind: "build", repo: { rootFiles: ["Package.swift"] }, planMemoryOptionsMb: [4096, 8192, 16384] });
  if (!pick.ok) throw new Error(pick.message);
  for (const id of ids) {
    expect(await run(tagMeasuredRun({ userId: user, provider: "gcp", providerVmId: `provider-${id}`, tag: autosizeTag(repoKey, "build", pick) }))).toBe(false);
    expect(await run(tagMeasuredRun({ userId: user, provider: "freestyle", providerVmId: `provider-${id}`, tag: autosizeTag(repoKey, "build", pick) }))).toBe(true);
  }
  // Still running: its peaks so far are not a finished run.
  expect(await run(listMeasuredRuns({ userId: user, repoKey, taskKind: "build" }))).toEqual([]);
  await sql`update cloud_vms set status = 'destroyed', destroyed_at = now() where user_id = ${user}`;
  // ids[1] never reported a sample: it is not a measured run.
  const runs = await run(listMeasuredRuns({ userId: user, repoKey, taskKind: "build" }));
  expect(runs).toEqual([{ vcpus: 8, memoryMb: 16384, storageMb: 65536, peakMemoryMb: 7000, meanBusyCpus: 3, peakDiskMb: 9000 }]);
  expect(await run(listMeasuredRuns({ userId: user, repoKey, taskKind: "test" }))).toEqual([]);
  expect(await run(listMeasuredRuns({ userId: `${user}-other`, repoKey, taskKind: "build" }))).toEqual([]);
  // 7000 MiB * 1.2 -> 9 GiB: lg, from the one run.
  const next = pickMachineSize({ taskKind: "build", repo: { rootFiles: ["Package.swift"] }, measuredRuns: runs, planMemoryOptionsMb: [4096, 8192, 16384] });
  expect(next).toMatchObject({ ok: true, pick: "lg", reason: "8 vCPU · 16 GB, picked from 1 earlier run" });
});
