/**
 * The one place SQL leaves the Worker. Rows come back as `unknown` and every
 * caller decodes them with a Schema, so no row shape is trusted.
 */
import { Context, Data, Effect, FiberRef, Layer } from "effect";
import postgres from "postgres";

export type SqlParam = string | number | boolean | null;

export class StoreError extends Data.TaggedError("StoreError")<{ readonly operation: string; readonly cause: unknown }> {}

export interface SqlClientService {
  readonly query: (operation: string, text: string, params: ReadonlyArray<SqlParam>) => Effect.Effect<ReadonlyArray<unknown>, StoreError>;
}

export class SqlClient extends Context.Tag("cmux-vm/SqlClient")<SqlClient, SqlClientService>() {}

/** The connection a request's queries share; opened by the first query, closed when the request ends. */
interface RequestConnection {
  sql: postgres.Sql | null;
}

const CurrentConnection = FiberRef.unsafeMake<RequestConnection | null>(null);

const connect = (connectionString: string) =>
  postgres(connectionString, { max: 1, fetch_types: false, prepare: false, connect_timeout: 5 });

const disconnect = (sql: postgres.Sql) => Effect.tryPromise(() => sql.end({ timeout: 1 })).pipe(Effect.ignore);

/**
 * Runs one request with a shared connection slot: every query in it uses one
 * Hyperdrive connection, opened by the first query and closed when the
 * request's handler returns (a streamed response body keeps flowing after
 * that, but nothing streamed touches the database). Workers cannot share a
 * socket between requests, so the slot is per request; Hyperdrive keeps the
 * real database connections warm. Install as the web handler's middleware.
 */
export const withRequestConnection = <A, E, R>(app: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  Effect.acquireUseRelease(
    Effect.sync((): RequestConnection => ({ sql: null })),
    (slot) => Effect.locally(app, CurrentConnection, slot),
    (slot) => (slot.sql === null ? Effect.void : disconnect(slot.sql)),
  );

/**
 * Postgres through a Hyperdrive binding. Inside `withRequestConnection` the
 * request's queries share one connection; outside it (tools, tests) each
 * query opens and closes its own.
 */
export const hyperdriveSqlLayer = (connectionString: string): Layer.Layer<SqlClient> =>
  Layer.succeed(SqlClient, {
    query: (operation, text, params) => {
      const run = (sql: postgres.Sql) =>
        Effect.tryPromise({
          try: async (): Promise<ReadonlyArray<unknown>> => Array.from(await sql.unsafe(text, [...params])),
          catch: (cause) => new StoreError({ operation, cause }),
        });
      return Effect.flatMap(FiberRef.get(CurrentConnection), (slot) => {
        if (slot === null) return Effect.acquireUseRelease(Effect.sync(() => connect(connectionString)), run, disconnect);
        if (slot.sql === null) slot.sql = connect(connectionString);
        return run(slot.sql);
      });
    },
  });
