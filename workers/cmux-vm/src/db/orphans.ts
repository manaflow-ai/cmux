/**
 * The lookups of the orphan sweeps (src/upstream/orphan-sweep.ts): which cmux VM ids a row still protects, and which
 * device tunnels nothing can use.
 */
import { Effect, Schema } from "effect";
import { SqlClient, StoreError, type SqlParam } from "./sql.ts";

/**
 * A VM whose row was deleted this long ago or longer, but which the provider still lists, is swept. The delete paths
 * (src/handlers/vms.ts deleteVmById, src/handlers/creation-cancellation.ts) delete at the provider before they write
 * deleted_at, so a VM still there an hour later is one whose provider delete did not take.
 */
export const ORPHAN_DELETED_ROW_GRACE_MS = 60 * 60_000;

const Row = Schema.Struct({ cmux_id: Schema.String });

const idsOf = (operation: string, text: string, params: ReadonlyArray<SqlParam>) =>
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const rows = yield* sql.query(operation, text, params);
    const decoded = yield* Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(
      Effect.mapError((cause) => new StoreError({ operation, cause })),
    );
    const ids: ReadonlySet<string> = new Set(decoded.map((row) => row.cmux_id));
    return ids;
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

const DeviceRow = Schema.Struct({ device_cmux_id: Schema.String, network: Schema.String });

/**
 * The device ids among `owners` (each with the tenant its tunnel's name gives) whose tunnel nothing can use, each with
 * its mesh's provider network id (the mesh's ownership row): no live device row, and an enroll attempt (migration 0018)
 * of that tenant and device that is resolved, or whose intent is revoked. Neither can commit a device row any more. A
 * device with no attempt row (enrolled without an intent), or whose mesh has no recorded network, is never named.
 */
export const sweepableTunnelDevices = (
  owners: ReadonlyArray<{ readonly tenantId: string; readonly deviceId: string }>,
): Effect.Effect<ReadonlyMap<string, string>, StoreError, SqlClient> =>
  Effect.gen(function* () {
    if (owners.length === 0) return new Map<string, string>();
    const sql = yield* SqlClient;
    const rows = yield* sql.query(
      "orphans.sweepableTunnelDevices",
      `WITH asked AS (
         SELECT owner->>'tenantId' AS tenant_id, owner->>'deviceId' AS device_cmux_id FROM jsonb_array_elements($1::text::jsonb) AS owner)
       SELECT DISTINCT a.device_cmux_id, r.upstream_id AS network FROM asked
         JOIN cmux_vm.mesh_device_intent_attempts a ON a.tenant_id = asked.tenant_id AND a.device_cmux_id = asked.device_cmux_id
         JOIN cmux_vm.mesh_device_intents i ON i.tenant_id = a.tenant_id AND i.mesh_cmux_id = a.mesh_cmux_id AND i.intent_id = a.intent_id
         JOIN cmux_vm.resources r ON r.tenant_id = a.tenant_id AND r.kind = 'mesh' AND r.cmux_id = a.mesh_cmux_id
        WHERE (a.resolved_at IS NOT NULL OR i.revoked_at IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM cmux_vm.mesh_devices d WHERE d.device_cmux_id = a.device_cmux_id AND d.deleted_at IS NULL)`,
      [JSON.stringify(owners.map((owner) => ({ tenantId: owner.tenantId, deviceId: owner.deviceId })))],
    );
    const decoded = yield* Schema.decodeUnknown(Schema.Array(DeviceRow))(rows).pipe(
      Effect.mapError((cause) => new StoreError({ operation: "orphans.sweepableTunnelDevices", cause })),
    );
    return new Map(decoded.map((row) => [row.device_cmux_id, row.network] as const));
  });
