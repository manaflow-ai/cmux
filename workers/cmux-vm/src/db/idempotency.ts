/**
 * Idempotency keys for creates (decision CMUX-VM-API V5). A key is scoped to
 * the tenant. The first request with a key runs and its public response is
 * stored; a retry with the same key and the same request gets that response
 * back without a second create. The same key with a different request, or
 * while the first is still running, is a 409.
 */
import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { Conflict, unavailable, type ServiceUnavailable } from "../errors.ts";
import type { TenantId } from "../lib/ids.ts";
import { SqlClient, StoreError } from "./sql.ts";

/** How long a completed key replays its response. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;

export type IdempotencyClaim =
  | { readonly _tag: "Started" }
  | { readonly _tag: "Replay"; readonly body: string }
  | { readonly _tag: "InProgress" }
  | { readonly _tag: "Mismatch" };

export interface IdempotencyStoreService {
  /** Claims `key` for this request, or reports what an earlier request with it did. Expired keys are replaced. */
  readonly claim: (
    tenantId: TenantId,
    key: string,
    fingerprint: string,
    now: Date,
  ) => Effect.Effect<IdempotencyClaim, StoreError>;
  /** Stores the response of the request that claimed `key`. */
  readonly complete: (tenantId: TenantId, key: string, fingerprint: string, body: string) => Effect.Effect<void, StoreError>;
  /** Releases a claim whose request failed, so a retry runs again. */
  readonly release: (tenantId: TenantId, key: string, fingerprint: string) => Effect.Effect<void, StoreError>;
}

export class IdempotencyStore extends Context.Tag("cmux-vm/IdempotencyStore")<IdempotencyStore, IdempotencyStoreService>() {}

/** Lowercase hex SHA-256 of the operation and its canonical request. */
export const fingerprintOf = (operation: string, request: unknown): Effect.Effect<string> =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${operation}\n${JSON.stringify(request)}`))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/**
 * Runs `create` at most once per (tenant, key, request). Without a key it
 * simply runs. The stored body is the public JSON response, which carries only
 * cmux ids.
 */
export const idempotent = <A, I, E, R>(options: {
  readonly tenantId: TenantId;
  readonly key: string | undefined;
  readonly operation: string;
  readonly request: unknown;
  readonly schema: Schema.Schema<A, I>;
  readonly create: Effect.Effect<A, E, R>;
}): Effect.Effect<A, E | Conflict | ServiceUnavailable, R | IdempotencyStore> =>
  Effect.gen(function* () {
    const { key } = options;
    if (key === undefined) return yield* options.create;
    const store = yield* IdempotencyStore;
    const fingerprint = yield* fingerprintOf(options.operation, options.request);
    const now = new Date(yield* Clock.currentTimeMillis);
    const claim = yield* store.claim(options.tenantId, key, fingerprint, now).pipe(Effect.mapError(() => unavailable()));
    switch (claim._tag) {
      case "Mismatch":
        return yield* Effect.fail(new Conflict({ message: "This Idempotency-Key was already used with a different request" }));
      case "InProgress":
        return yield* Effect.fail(new Conflict({ message: "A request with this Idempotency-Key is still in progress" }));
      case "Replay":
        return yield* Schema.decode(Schema.parseJson(options.schema))(claim.body).pipe(Effect.mapError(() => unavailable()));
      case "Started":
        break;
    }
    const result = yield* options.create.pipe(
      Effect.tapErrorCause(() => store.release(options.tenantId, key, fingerprint).pipe(Effect.ignore)),
    );
    const body = yield* Schema.encode(Schema.parseJson(options.schema))(result).pipe(Effect.option);
    if (Option.isSome(body)) {
      // The create succeeded; a failure to store its replay only costs a later retry its replay.
      yield* store.complete(options.tenantId, key, fingerprint, body.value).pipe(Effect.ignore);
    }
    return result;
  });

const ClaimRow = Schema.Struct({
  fingerprint: Schema.String,
  state: Schema.Literal("pending", "completed"),
  response_body: Schema.NullOr(Schema.String),
});

export const sqlIdempotencyStoreLayer: Layer.Layer<IdempotencyStore, never, SqlClient> = Layer.effect(
  IdempotencyStore,
  Effect.map(SqlClient, (sql) => ({
    claim: (tenantId, key, fingerprint, now) =>
      Effect.gen(function* () {
        yield* sql.query(
          "idempotency.expire",
          "DELETE FROM cmux_vm_idempotency_keys WHERE tenant_id = $1 AND key = $2 AND expires_at <= $3::timestamptz",
          [tenantId, key, now.toISOString()],
        );
        const inserted = yield* sql.query(
          "idempotency.claim",
          `INSERT INTO cmux_vm_idempotency_keys (tenant_id, key, fingerprint, state, created_at, expires_at)
           VALUES ($1, $2, $3, 'pending', $4::timestamptz, $5::timestamptz)
           ON CONFLICT (tenant_id, key) DO NOTHING
           RETURNING key`,
          [tenantId, key, fingerprint, now.toISOString(), new Date(now.getTime() + IDEMPOTENCY_TTL_MS).toISOString()],
        );
        if (inserted.length > 0) return { _tag: "Started" } as const;
        const rows = yield* sql
          .query(
            "idempotency.read",
            "SELECT fingerprint, state, response_body FROM cmux_vm_idempotency_keys WHERE tenant_id = $1 AND key = $2",
            [tenantId, key],
          )
          .pipe(
            Effect.flatMap((found) =>
              Schema.decodeUnknown(Schema.Array(ClaimRow))(found).pipe(
                Effect.mapError((cause) => new StoreError({ operation: "idempotency.read", cause })),
              ),
            ),
          );
        const row = rows[0];
        // Deleted between the insert and the read: treat as still running; the caller retries.
        if (row === undefined) return { _tag: "InProgress" } as const;
        if (row.fingerprint !== fingerprint) return { _tag: "Mismatch" } as const;
        if (row.state === "pending" || row.response_body === null) return { _tag: "InProgress" } as const;
        return { _tag: "Replay", body: row.response_body } as const;
      }),
    complete: (tenantId, key, fingerprint, body) =>
      sql
        .query(
          "idempotency.complete",
          `UPDATE cmux_vm_idempotency_keys SET state = 'completed', response_status = 201, response_body = $4
            WHERE tenant_id = $1 AND key = $2 AND fingerprint = $3 AND state = 'pending'`,
          [tenantId, key, fingerprint, body],
        )
        .pipe(Effect.asVoid),
    release: (tenantId, key, fingerprint) =>
      sql
        .query(
          "idempotency.release",
          "DELETE FROM cmux_vm_idempotency_keys WHERE tenant_id = $1 AND key = $2 AND fingerprint = $3 AND state = 'pending'",
          [tenantId, key, fingerprint],
        )
        .pipe(Effect.asVoid),
  })),
);
