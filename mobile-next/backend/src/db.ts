// PlanetScale access. The v2 driver does not bind parameters, so every query
// goes through `q`, which escapes values with sql-escaper.
import { connect, type Connection } from "@planetscale/database";
import { format, type SqlValue } from "sql-escaper";
import type { Env } from "./env";

export type Db = {
  rows<T>(sql: string, values?: SqlValue[]): Promise<T[]>;
  one<T>(sql: string, values?: SqlValue[]): Promise<T | null>;
  exec(sql: string, values?: SqlValue[]): Promise<{ rowsAffected: number }>;
};

export function q(sql: string, values: SqlValue[] = []): string {
  return format(sql, values, false, "Z");
}

export function createDb(env: Env): Db {
  let conn: Connection | null = null;
  const c = () =>
    (conn ??= connect({
      host: env.DATABASE_HOST,
      username: env.DATABASE_USERNAME,
      password: env.DATABASE_PASSWORD,
      fetch: (url, init) => {
        if (init) delete init.cache;
        return fetch(url, init);
      },
    }));
  return {
    async rows<T>(sql: string, values?: SqlValue[]) {
      return (await c().execute(q(sql, values))).rows as T[];
    },
    async one<T>(sql: string, values?: SqlValue[]) {
      const r = (await c().execute(q(sql, values))).rows as T[];
      return r[0] ?? null;
    },
    async exec(sql: string, values?: SqlValue[]) {
      const r = await c().execute(q(sql, values));
      return { rowsAffected: r.rowsAffected };
    },
  };
}

/** MySQL DATETIME(3) strings are UTC; expose ISO-8601. */
export function iso(value: string | null | undefined): string | null {
  if (!value) return null;
  return `${value.replace(" ", "T")}${value.includes(".") ? "" : ".000"}Z`;
}
