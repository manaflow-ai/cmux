/** The ownership lookup of the orphan sweep (src/upstream/orphan-sweep.ts): which cmux VM ids have a row of any state. */
import { Effect, Schema } from "effect";
import { SqlClient, StoreError } from "./sql.ts";

const Row = Schema.Struct({ cmux_id: Schema.String });

/** The ids among `cmuxIds` that cmux_vm.resources names, live, uncommitted or deleted. */
export const recordedVmIds = (cmuxIds: ReadonlyArray<string>): Effect.Effect<ReadonlySet<string>, StoreError, SqlClient> =>
  Effect.gen(function* () {
    if (cmuxIds.length === 0) return new Set<string>();
    const sql = yield* SqlClient;
    const rows = yield* sql.query(
      "orphans.recordedVmIds",
      `SELECT cmux_id FROM cmux_vm.resources WHERE kind = 'vm' AND cmux_id IN (SELECT jsonb_array_elements_text($1::text::jsonb))`,
      [JSON.stringify(cmuxIds)],
    );
    const decoded = yield* Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(
      Effect.mapError((cause) => new StoreError({ operation: "orphans.recordedVmIds", cause })),
    );
    return new Set(decoded.map((row) => row.cmux_id));
  });
