/** The ownership lookups of the orphan sweep (src/upstream/orphan-sweep.ts): which cmux VM ids a row still protects. */
import { Effect, Schema } from "effect";
import { SqlClient, StoreError } from "./sql.ts";

/**
 * A VM whose row was deleted this long ago or longer, but which the provider still lists, is swept. The delete paths
 * (src/handlers/vms.ts deleteVmById, src/handlers/creation-cancellation.ts) delete at the provider before they write
 * deleted_at, so a VM still there an hour later is one whose provider delete did not take.
 */
export const ORPHAN_DELETED_ROW_GRACE_MS = 60 * 60_000;

const Row = Schema.Struct({ cmux_id: Schema.String });

const idsOf = (operation: string, text: string, params: ReadonlyArray<unknown>) =>
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const rows = yield* sql.query(operation, text, params);
    const decoded = yield* Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(
      Effect.mapError((cause) => new StoreError({ operation, cause })),
    );
    return new Set(decoded.map((row) => row.cmux_id)) as ReadonlySet<string>;
  });

/**
 * The ids among `cmuxIds` that cmux_vm.resources protects: a live row (committed or uncommitted), or a row deleted
 * less than ORPHAN_DELETED_ROW_GRACE_MS ago. A row deleted longer ago no longer protects its VM.
 */
export const recordedVmIds = (cmuxIds: ReadonlyArray<string>): Effect.Effect<ReadonlySet<string>, StoreError, SqlClient> =>
  cmuxIds.length === 0
    ? Effect.succeed(new Set<string>())
    : idsOf(
      "orphans.recordedVmIds",
      `SELECT cmux_id FROM cmux_vm.resources WHERE kind = 'vm' AND cmux_id IN (SELECT jsonb_array_elements_text($1::text::jsonb))
         AND (deleted_at IS NULL OR deleted_at > now() - make_interval(secs => $2::double precision))`,
      [JSON.stringify(cmuxIds), ORPHAN_DELETED_ROW_GRACE_MS / 1000],
    );

/** The ids among `cmuxIds` whose row is deleted (any age): the sweep's reason for those is `deleted_row`. */
export const deletedVmIds = (cmuxIds: ReadonlyArray<string>): Effect.Effect<ReadonlySet<string>, StoreError, SqlClient> =>
  cmuxIds.length === 0
    ? Effect.succeed(new Set<string>())
    : idsOf(
      "orphans.deletedVmIds",
      `SELECT cmux_id FROM cmux_vm.resources WHERE kind = 'vm' AND cmux_id IN (SELECT jsonb_array_elements_text($1::text::jsonb))
         AND deleted_at IS NOT NULL`,
      [JSON.stringify(cmuxIds)],
    );
