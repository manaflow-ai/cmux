import { PgClient } from "@effect/sql-pg";
import * as Statement from "@effect/sql/Statement";
import * as OtelResource from "@effect/opentelemetry/Resource";
import * as OtelTracer from "@effect/opentelemetry/Tracer";
import * as PgDrizzle from "drizzle-orm/effect-postgres";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as ManagedRuntime from "effect/ManagedRuntime";
import { types } from "pg";
import * as schema from "./schema";
import { tagCloudDbQuery } from "./queryTags";

const database = PgDrizzle.makeWithDefaults({ schema });

/** Effect-native PostgreSQL service shared by repositories in one workload. */
export class Database extends Context.Tag("cmux/EffectDatabase")<
  Database, Effect.Effect.Success<typeof database>
>() {}

export type DatabasePoolOptions = Omit<PgClient.PgClientConfig, "types"> & {
  readonly maxConnections: number;
  readonly applicationName: string;
};

/** The caller owns this layer's scope; no connection is created per query. */
export function makeDatabaseLayer(options: DatabasePoolOptions) {
  const client = PgClient.layer({
    ...options,
    minConnections: options.minConnections ?? 0,
    idleTimeout: options.idleTimeout ?? "5 seconds",
    connectTimeout: options.connectTimeout ?? "750 millis",
    types: {
      getTypeParser(typeId, format) {
        // Drizzle owns date/time and interval decoding. Node-postgres must
        // leave these values intact, including arrays and timezone offsets.
        if ([1184, 1114, 1082, 1186, 1231, 1115, 1185, 1187, 1182].includes(typeId)) {
          return (value: string) => value;
        }
        return types.getTypeParser(typeId, format);
      },
    },
  });
  // DefaultServices disables SQL/parameter logging and result caching.
  return Layer.effect(Database, database).pipe(
    Layer.provideMerge(client),
    // Effect SQL spans use the application's existing OpenTelemetry provider,
    // so Axiom receives connection, transaction, and query timings under the
    // same trace as the request-level authorization spans.
    Layer.provide(
      OtelTracer.layerGlobal.pipe(
        Layer.provide(OtelResource.layer({ serviceName: options.applicationName })),
      ),
    ),
    Layer.provide(Statement.setTransformer((statement, sql) => Effect.sync(() => {
      const [text, parameters] = statement.compile();
      return sql.unsafe(tagCloudDbQuery(text), parameters);
    }))),
  );
}

/** Create once at the service composition root, reuse, then dispose on shutdown. */
export function makeDatabaseRuntime(options: DatabasePoolOptions) {
  return ManagedRuntime.make(makeDatabaseLayer(options));
}
