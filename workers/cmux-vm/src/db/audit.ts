/**
 * Audit log of mutations (decision CMUX-VM-API V5): tenant, actor (user or
 * API key id), action and public resource id, plus whether the provider call
 * succeeded. Never secrets, command bodies or provider ids.
 */
import { Clock, Context, Effect, Layer } from "effect";
import { actorRef, type Principal } from "../domain/principal.ts";
import type { TenantId } from "../lib/ids.ts";
import { SqlClient, type StoreError } from "./sql.ts";

export type AuditAction =
  | "snapshot.create"
  | "snapshot.delete"
  | "terminal.open"
  | "terminal.attach"
  | "terminal.close";

export interface AuditEntry {
  readonly tenantId: TenantId;
  /** `user:<id>` or `key:<id>`. */
  readonly actor: string;
  readonly action: AuditAction;
  readonly resourceId: string;
  readonly outcome: "succeeded" | "failed";
  readonly at: Date;
}

export interface AuditLogService {
  readonly record: (entry: AuditEntry) => Effect.Effect<void, StoreError>;
}

export class AuditLog extends Context.Tag("cmux-vm/AuditLog")<AuditLog, AuditLogService>() {}

/**
 * Records one entry for the caller. The mutation already happened (or failed)
 * by the time this runs, so a write failure is reported to the Worker log and
 * does not change the response: failing it would invite a retry of a mutation
 * that already took effect.
 */
export const audit = (principal: Principal, action: AuditAction, resourceId: string, outcome: AuditEntry["outcome"]) =>
  Effect.gen(function* () {
    const log = yield* AuditLog;
    const at = new Date(yield* Clock.currentTimeMillis);
    yield* log
      .record({ tenantId: principal.tenantId, actor: actorRef(principal.actor), action, resourceId, outcome, at })
      .pipe(
        Effect.catchAll((error) =>
          Effect.sync(() => console.error(JSON.stringify({ event: "audit_write_failed", operation: error.operation, action }))),
        ),
      );
  });

export const sqlAuditLogLayer: Layer.Layer<AuditLog, never, SqlClient> = Layer.effect(
  AuditLog,
  Effect.map(SqlClient, (sql) => ({
    record: (entry) =>
      sql
        .query(
          "audit.record",
          `INSERT INTO cmux_vm_audit_log (tenant_id, actor, action, resource_id, outcome, created_at)
           VALUES ($1, $2, $3, $4, $5, $6::timestamptz)`,
          [entry.tenantId, entry.actor, entry.action, entry.resourceId, entry.outcome, entry.at.toISOString()],
        )
        .pipe(Effect.asVoid),
  })),
);
