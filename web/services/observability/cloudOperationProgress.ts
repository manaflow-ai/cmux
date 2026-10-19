import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import type { CloudTelemetrySpan } from "./cloudTelemetryContract";

export function cloudOperationId(value: string | null | undefined): string | undefined {
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value) ? value : undefined;
}

/** Progress writes run beside provider work. They never delay or fail the Cloud operation. */
export class CloudOperationProgress {
  private readonly pending = new Set<Promise<void>>();
  private count = 0;
  constructor(private readonly userId: string, private readonly operationId: string) {}

  async run<T>(phase: CloudTelemetrySpan["phase"], work: () => Promise<T>): Promise<T> {
    if (this.count++ >= 64) return work();
    const id = randomUUID();
    const startedAt = new Date();
    const started = this.write(id, phase, "running", startedAt);
    try {
      const result = await work();
      this.track(started.then(() => this.write(id, phase, "success", startedAt, new Date())));
      return result;
    } catch (error) {
      this.track(started.then(() => this.write(id, phase, "failure", startedAt, new Date())));
      throw error;
    }
  }

  async flush(): Promise<void> { await Promise.all(this.pending); }

  private track(promise: Promise<void>): void {
    this.pending.add(promise);
    void promise.finally(() => this.pending.delete(promise));
  }

  private async write(id: string, phase: string, outcome: string, start: Date, end?: Date): Promise<void> {
    try {
      await cloudDb().execute(sql`
        insert into cloud_operation_steps (user_id, operation_id, step_id, phase, outcome, started_at, ended_at)
        values (${this.userId}, ${this.operationId}::uuid, ${id}::uuid, ${phase}, ${outcome}, ${start.toISOString()}::timestamptz, ${end?.toISOString() ?? null}::timestamptz)
        on conflict (user_id, operation_id, step_id) do update set outcome = excluded.outcome, ended_at = excluded.ended_at
      `);
    } catch {
      console.error("cmux.cloud.progress.write_failed", { phase, outcome });
    }
  }
}

export async function readCloudOperationProgress(userId: string, operationId: string) {
  const rows = await cloudDb().execute(sql`
    select step_id::text, phase, outcome, started_at, ended_at from cloud_operation_steps
    where user_id = ${userId} and operation_id = ${operationId}::uuid and expires_at > now()
    order by started_at limit 64
  `);
  return rows.map((row) => ({
    id: String(row.step_id), phase: String(row.phase), outcome: String(row.outcome),
    startedAtMs: new Date(row.started_at as string).getTime(),
    endedAtMs: row.ended_at ? new Date(row.ended_at as string).getTime() : null,
  }));
}
