/**
 * Cloudflare-side Drizzle client for the existing Aurora/Postgres database.
 *
 * Hyperdrive owns connection pooling and TLS at the edge. The application
 * repositories only need the small `cloudDb()` surface, so Wrangler aliases
 * the web-only Vercel/AWS client to this module in the Worker bundle.
 */
import { drizzle } from "drizzle-orm/postgres-js";
import postgres, { type Sql } from "postgres";
import * as schema from "../../../web/db/schema";

type CloudDb = ReturnType<typeof drizzle<typeof schema>>;

export type HyperdriveBindingLike = {
  readonly connectionString?: string;
};

/**
 * Return a Drizzle facade over one request-scoped postgres.js client.
 *
 * Hyperdrive owns the long-lived origin pool. Keeping a postgres.js client or
 * Drizzle object in module state would make the Worker retain edge sockets
 * across requests and would bypass Hyperdrive's request lifecycle. A fresh
 * client is cheap, because Hyperdrive reuses the database-side connection.
 */
export function cloudDb(binding?: HyperdriveBindingLike): CloudDb {
  const connectionString = binding?.connectionString?.trim();
  if (!connectionString) throw new Error("HYPERDRIVE connection is not configured");

  const sql = postgres(connectionString, {
    // Hyperdrive supports named prepared statements and reuses the origin
    // connection, so keep postgres.js preparation enabled.
    prepare: true,
    max: 5,
    fetch_types: false,
  });
  return drizzle({ client: sql as Sql, schema }) as CloudDb;
}
