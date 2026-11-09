/**
 * The orphan sweep's ownership lookups (src/db/orphans.ts) on PGlite: a live or uncommitted row, or one deleted within
 * the grace, protects its VM; a row deleted longer ago does not (ask c-a0f5525efc).
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { deletedVmIds, ORPHAN_DELETED_ROW_GRACE_MS, recordedVmIds } from "../../src/db/orphans.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

const id = (n: number) => `vm_${String(n).padStart(26, "0")}`;

it("protects live, uncommitted and recently deleted VM rows, and names every deleted one", async () => {
  const pg = new PGlite();
  for (const migration of [ownership, s2, creationReceipts, uncommittedCreations]) await pg.exec(migration);
  const insert = (cmuxId: string, extra: string) =>
    pg.exec(`INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by${extra === "" ? "" : `, ${extra.split("=")[0]}`})
             VALUES ('${cmuxId}', 'team_alpha', 'vm', 'up-${cmuxId}', 'key:test'${extra === "" ? "" : `, ${extra.split("=")[1]}`})`);
  await insert(id(1), "");
  await insert(id(2), "committed=false");
  await insert(id(3), "deleted_at=now()");
  const graceMinutes = ORPHAN_DELETED_ROW_GRACE_MS / 60_000;
  await insert(id(5), `deleted_at=now() - interval '${graceMinutes + 1} minutes'`);
  await insert(id(6), `deleted_at=now() - interval '${graceMinutes - 5} minutes'`);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  const all = [id(1), id(2), id(3), id(4), id(5), id(6)];
  const found = await Effect.runPromise(Effect.provide(recordedVmIds(all), sql));
  expect([...found].sort()).toEqual([id(1), id(2), id(3), id(6)]);
  const deleted = await Effect.runPromise(Effect.provide(deletedVmIds(all), sql));
  expect([...deleted].sort()).toEqual([id(3), id(5), id(6)]);
  expect([...(await Effect.runPromise(Effect.provide(recordedVmIds([]), sql)))]).toEqual([]);
  expect([...(await Effect.runPromise(Effect.provide(deletedVmIds([]), sql)))]).toEqual([]);
});
