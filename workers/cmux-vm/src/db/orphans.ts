/**
 * The lookups of the orphan sweeps (src/upstream/orphan-sweep.ts): which cmux VM ids have a row of any state, and which
 * device tunnels nothing can use.
 */
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

const DeviceRow = Schema.Struct({ device_cmux_id: Schema.String });

/**
 * The device ids among `owners` (each with the tenant its tunnel's name gives) whose tunnel nothing can use: no live
 * device row, and an enroll attempt (migration 0018) of that tenant and device that is resolved, or whose intent is
 * revoked. Neither can commit a device row any more. A device with no attempt row (enrolled without an intent) is
 * never named.
 */
export const sweepableTunnelDevices = (
  owners: ReadonlyArray<{ readonly tenantId: string; readonly deviceId: string }>,
): Effect.Effect<ReadonlySet<string>, StoreError, SqlClient> =>
  Effect.gen(function* () {
    if (owners.length === 0) return new Set<string>();
    const sql = yield* SqlClient;
    const rows = yield* sql.query(
      "orphans.sweepableTunnelDevices",
      `WITH asked AS (
         SELECT owner->>'tenantId' AS tenant_id, owner->>'deviceId' AS device_cmux_id FROM jsonb_array_elements($1::text::jsonb) AS owner)
       SELECT DISTINCT a.device_cmux_id FROM asked
         JOIN cmux_vm.mesh_device_intent_attempts a ON a.tenant_id = asked.tenant_id AND a.device_cmux_id = asked.device_cmux_id
         JOIN cmux_vm.mesh_device_intents i ON i.tenant_id = a.tenant_id AND i.mesh_cmux_id = a.mesh_cmux_id AND i.intent_id = a.intent_id
        WHERE (a.resolved_at IS NOT NULL OR i.revoked_at IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM cmux_vm.mesh_devices d WHERE d.device_cmux_id = a.device_cmux_id AND d.deleted_at IS NULL)`,
      [JSON.stringify(owners.map((owner) => ({ tenantId: owner.tenantId, deviceId: owner.deviceId })))],
    );
    const decoded = yield* Schema.decodeUnknown(Schema.Array(DeviceRow))(rows).pipe(
      Effect.mapError((cause) => new StoreError({ operation: "orphans.sweepableTunnelDevices", cause })),
    );
    return new Set(decoded.map((row) => row.device_cmux_id));
  });
