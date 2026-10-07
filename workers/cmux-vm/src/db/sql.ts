/**
 * The one place SQL leaves the Worker. Rows come back as `unknown` and every
 * caller decodes them with a Schema, so no row shape is trusted.
 */
import { Context, Data, Effect, Layer } from "effect";
import postgres from "postgres";

export type SqlParam = string | number | boolean | null;

export class StoreError extends Data.TaggedError("StoreError")<{ readonly operation: string; readonly cause: unknown }> {}

export interface SqlClientService {
  readonly query: (operation: string, text: string, params: ReadonlyArray<SqlParam>) => Effect.Effect<ReadonlyArray<unknown>, StoreError>;
}

export class SqlClient extends Context.Tag("cmux-vm/SqlClient")<SqlClient, SqlClientService>() {}

/**
 * Postgres through a Hyperdrive binding. Workers cannot share a socket between
 * requests, so each query opens one pooled Hyperdrive connection and closes it;
 * Hyperdrive keeps the real database connections warm.
 *
 * TODO(S2): one connection per request instead of per query. Today an
 * API-key request costs two Hyperdrive connections (key lookup, then the
 * ownership lookup), each with its own connect and close.
 */
export const hyperdriveSqlLayer = (connectionString: string): Layer.Layer<SqlClient> =>
  Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.acquireUseRelease(
        Effect.sync(() => postgres(connectionString, { max: 1, fetch_types: false, prepare: false, connect_timeout: 5 })),
        (sql) =>
          Effect.tryPromise({
            try: async (): Promise<ReadonlyArray<unknown>> => Array.from(await sql.unsafe(text, [...params])),
            catch: (cause) => new StoreError({ operation, cause }),
          }),
        (sql) => Effect.tryPromise(() => sql.end({ timeout: 1 })).pipe(Effect.ignore),
      ),
  });
