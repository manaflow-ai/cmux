/** The orphan sweep's ownership lookup (src/db/orphans.ts) on PGlite: any row of any state counts as recorded. */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { recordedVmIds } from "../../src/db/orphans.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

const id = (n: number) => `vm_${String(n).padStart(26, "0")}`;

it("names live, uncommitted and deleted VM rows, and nothing else", async () => {
  const pg = new PGlite();
  for (const migration of [ownership, s2, creationReceipts, uncommittedCreations]) await pg.exec(migration);
  const insert = (cmuxId: string, extra: string) =>
    pg.exec(`INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by${extra === "" ? "" : `, ${extra.split("=")[0]}`})
             VALUES ('${cmuxId}', 'team_alpha', 'vm', 'up-${cmuxId}', 'key:test'${extra === "" ? "" : `, ${extra.split("=")[1]}`})`);
  await insert(id(1), "");
  await insert(id(2), "committed=false");
  await insert(id(3), "deleted_at=now()");
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  const found = await Effect.runPromise(Effect.provide(recordedVmIds([id(1), id(2), id(3), id(4)]), sql));
  expect([...found].sort()).toEqual([id(1), id(2), id(3)]);
  expect([...(await Effect.runPromise(Effect.provide(recordedVmIds([]), sql)))]).toEqual([]);
});
