import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { PgClient } from "@effect/sql-pg";
import * as PgDrizzle from "drizzle-orm/effect-postgres";
import { count } from "drizzle-orm";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import { types } from "pg";
import postgres, { type Sql } from "postgres";
import * as schema from "../db/schema";
import { cloudVms } from "../db/schema";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await sql?.end();
});

describe("Drizzle Effect integration", () => {
  dbTest("queries Postgres through the Effect-backed Drizzle driver", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (
        user_id,
        provider,
        provider_vm_id,
        image_id,
        image_version,
        status,
        idempotency_key
      )
      values (
        'user-drizzle-effect',
        'e2b',
        'effect-provider-vm-1',
        'cmuxd-ws:test',
        '2026-04-25.1',
        'running',
        'effect-idem-1'
      )
    `;

    const program = Effect.gen(function* () {
      const db = yield* PgDrizzle.makeWithDefaults({ schema });
      const rows = yield* db.select({ total: count() }).from(cloudVms);
      return rows[0]?.total ?? 0;
    });

    const total = await Effect.runPromise(
      program.pipe(
        Effect.provide(
          PgClient.layer({
            url: Redacted.make(databaseURL()),
            types: {
              getTypeParser: (typeId, format) => {
                if ([1184, 1114, 1082, 1186, 1231, 1115, 1185, 1187, 1182].includes(typeId)) {
                  return (value: string) => value;
                }
                return types.getTypeParser(typeId, format);
              },
            },
          }),
        ),
      ),
    );

    expect(total).toBe(1);
  });
});
