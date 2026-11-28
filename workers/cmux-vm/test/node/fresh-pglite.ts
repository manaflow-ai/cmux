/**
 * One in-process Postgres (PGlite) per test file, emptied before each test, instead of a new one per test.
 *
 * A PGlite boot is a WASM Postgres start: about 4 s on an idle lane VM, against 0.2 s for all 19 migrations. A suite
 * that booted one in every beforeEach and never closed it held one instance per test, and with the files running in
 * parallel on a shared runner the hooks crept up until five files' hooks passed the 30 s hookTimeout at once
 * (cmux-vm.yml check, run 46084954489, 2026-11-27 23:55Z), which skipped image roll 589544f1's production deploy.
 * Raising the timeout (10 s, then 30 s) only moved the line; this removes the per-test boot.
 *
 * Each call returns the file's instance with every schema the migrations or a test made dropped (cmux_vm, public,
 * any other), the session reset (DISCARD ALL) and any open transaction rolled back, so a test sees an empty database
 * as a new PGlite would show it.
 */
import { PGlite } from "@electric-sql/pglite";
import { afterAll } from "vitest";

let shared: PGlite | undefined;

afterAll(async () => {
  await shared?.close();
  shared = undefined;
});

export async function freshPg(): Promise<PGlite> {
  if (!shared) {
    shared = new PGlite();
    await shared.waitReady;
    return shared;
  }
  const pg = shared;
  // A test may end inside a transaction it opened (a refused statement in BEGIN); ROLLBACK outside one only warns.
  await pg.exec("ROLLBACK");
  await pg.exec("DISCARD ALL");
  const { rows } = await pg.query<{ nspname: string }>(
    "SELECT nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND nspname NOT LIKE 'pg_temp_%' AND nspname NOT LIKE 'pg_toast_temp_%'",
  );
  for (const { nspname } of rows) await pg.exec(`DROP SCHEMA "${nspname.replaceAll('"', '""')}" CASCADE`);
  await pg.exec("CREATE SCHEMA public");
  return pg;
}
