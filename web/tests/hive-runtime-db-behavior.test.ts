import { afterAll, beforeAll, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { bindHiveRuntimeJournal, readHiveRuntime } from "../services/vms/runtimeRegistry";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
let db: Sql;
const owner = `hive-test-${randomUUID()}`;
beforeAll(() => {
  if (enabled) db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
});
afterAll(async () => {
  if (!enabled) return;
  await db`delete from cloud_runtimes where owner_team_id = ${owner}`;
  await db`delete from cloud_vms where user_id = ${owner}`;
  await closeCloudDbForTests();
  await db.end();
});

async function fixture() {
  const [vm] = await db`insert into cloud_vms (user_id, billing_team_id, provider, image_id, status)
    values (${owner}, ${owner}, 'freestyle', 'hive-test', 'running') returning id`;
  const [runtime] = await db`insert into cloud_runtimes (owner_team_id, machine_id)
    values (${owner}, ${vm.id}) returning id`;
  return { runtimeId: runtime.id as string, machineId: vm.id as string, generation: 1 };
}

dbTest("runtime and root/child identities survive compute deletion and a fresh read", async () => {
  const placement = await fixture();
  await db`insert into cloud_runtime_agent_bindings (runtime_id, codex_thread_id, root_chat_id, parent_chat_id)
    values (${placement.runtimeId}, 'root', 'root', null), (${placement.runtimeId}, 'child', 'root', 'root')`;
  const original = await Effect.runPromise(readHiveRuntime(owner, placement.runtimeId));
  expect(original?.runtime.id).not.toBe(placement.machineId);
  expect(await Effect.runPromise(readHiveRuntime('foreign', placement.runtimeId))).toBeNull();
  await db`delete from cloud_vms where id = ${placement.machineId}`;
  const reloaded = await Effect.runPromise(readHiveRuntime(owner, placement.runtimeId));
  expect(reloaded?.runtime.id).toBe(placement.runtimeId);
  expect(reloaded?.runtime.machineId).toBeNull();
  expect(reloaded?.machine).toBeNull();
  const bindings = await db`select codex_thread_id, root_chat_id, parent_chat_id from cloud_runtime_agent_bindings
    where runtime_id = ${placement.runtimeId} order by codex_thread_id`;
  expect([...bindings]).toEqual([
    { codex_thread_id: 'child', root_chat_id: 'root', parent_chat_id: 'root' },
    { codex_thread_id: 'root', root_chat_id: 'root', parent_chat_id: null },
  ]);
});

dbTest("journal binding rejects stale generation, machine, account and lineage before mutation", async () => {
  const placement = await fixture();
  const input = { ownerTeamId: owner, placement, journalSessionId: `session_${randomUUID().replaceAll('-', '')}` };
  const bind = (value: typeof input) => Effect.runPromise(bindHiveRuntimeJournal(value));
  expect(await bind({ ...input, placement: { ...placement, generation: 2 } })).toBe(false);
  expect(await bind({ ...input, placement: { ...placement, machineId: randomUUID() } })).toBe(false);
  expect(await bind({ ...input, ownerTeamId: 'foreign' })).toBe(false);
  expect((await Effect.runPromise(readHiveRuntime(owner, placement.runtimeId)))?.runtime.journalSessionId).toBeNull();
  expect(await bind(input)).toBe(true);
  expect(await bind(input)).toBe(true);
  expect(await bind({ ...input, journalSessionId: `session_${randomUUID().replaceAll('-', '')}` })).toBe(false);
  await db`update cloud_runtimes set placement_generation = 2 where id = ${placement.runtimeId}`;
  expect(await bind(input)).toBe(false);
  expect((await Effect.runPromise(readHiveRuntime(owner, placement.runtimeId)))?.runtime.journalSessionId).toBe(input.journalSessionId);
});

dbTest("schema enforces one runtime per VM and positive placement generations", async () => {
  const placement = await fixture();
  await expect(db`insert into cloud_runtimes (owner_team_id, machine_id) values (${owner}, ${placement.machineId})`).rejects.toMatchObject({ code: '23505' });
  await expect(db`update cloud_runtimes set placement_generation = 0 where id = ${placement.runtimeId}`).rejects.toMatchObject({ code: '23514' });
});
