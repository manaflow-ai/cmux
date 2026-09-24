import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/durable-sqlite";
import { z } from "zod";
import { identifier } from "../contracts/common";
import { OperationError } from "../errors";
import { applyStorageMigrations } from "./migrations";
import { socketReservations } from "./socket-schema";
import type { UsageScope } from "./user-usage";

const SessionSchema = z.strictObject({
  userId: identifier, teamId: identifier, sessionId: identifier.max(128), deviceKey: z.string().regex(/^[a-f0-9]{64}$/),
});
export interface SocketReservation {
  userId: string; teamId: string; sessionId: string; deviceKey: string;
  outputBytes: number; outputMessages: number; outputRevision: number;
}

/** Reservations persist across eviction and are never expired while a socket may still exist. */
export class UserSocketStore {
  private readonly db;
  private readonly scopeKey: string;
  constructor(readonly storage: DurableObjectStorage, scope: UsageScope, options?: { initialize?: boolean }) {
    this.db = drizzle(storage, { schema: { socketReservations } });
    this.scopeKey = JSON.stringify([scope.environment, scope.projectId]);
    if (options?.initialize !== false) applyStorageMigrations(storage);
  }

  reserveSocket(input: { userId: string; teamId: string; sessionId: string; deviceKey: string }): void {
    const value = SessionSchema.parse(input);
    try {
      this.storage.transactionSync(() => {
        const existing = this.get(value.userId, value.sessionId);
        if (existing) {
          if (existing.teamId !== value.teamId || existing.deviceKey !== value.deviceKey) throw new OperationError("identity_mismatch", 403);
          return;
        }
        this.db.insert(socketReservations).values({ scopeKey: this.scopeKey, ...value }).run();
      });
    } catch (error) {
      if (String(error).includes("socket_capacity")) throw new OperationError("rate_limited", 429, true, 1000);
      throw error;
    }
  }

  /** Sequence checks keep uncertain RPC retries from overwriting a newer reservation. */
  setOutput(userId: string, sessionId: string, revision: number, bytes: number, messages: number): void {
    identifier.parse(userId); identifier.parse(sessionId);
    for (const value of [revision, bytes, messages]) if (!Number.isSafeInteger(value) || value < 0) throw new OperationError("invalid_request", 400);
    if (bytes > 2 * 1024 * 1024 || messages > 1024) throw new OperationError("slow_consumer", 429, true, 1000);
    try {
      this.storage.transactionSync(() => {
        const current = this.get(userId, sessionId);
        if (!current) throw new OperationError("resync_required", 409, true);
        if (revision === current.outputRevision && bytes === current.outputBytes && messages === current.outputMessages) return;
        if (revision !== current.outputRevision + 1) throw new OperationError("revision_conflict", 409, true);
        this.db.run(sql`UPDATE "socket_reservations" SET "output_bytes" = ${bytes}, "output_messages" = ${messages}, "output_revision" = ${revision} WHERE "scope_key" = ${this.scopeKey} AND "user_id" = ${userId} AND "session_id" = ${sessionId}`);
      });
    } catch (error) {
      if (String(error).includes("socket_output_capacity")) throw new OperationError("slow_consumer", 429, true, 1000);
      throw error;
    }
  }

  releaseSocket(userId: string, sessionId: string): void {
    identifier.parse(userId); identifier.parse(sessionId);
    this.db.run(sql`DELETE FROM "socket_reservations" WHERE "scope_key" = ${this.scopeKey} AND "user_id" = ${userId} AND "session_id" = ${sessionId}`);
  }

  listSocketReservations(userId: string): SocketReservation[] {
    identifier.parse(userId);
    return this.db.all<SocketReservation>(sql`SELECT "user_id" AS "userId", "team_id" AS "teamId", "session_id" AS "sessionId", "device_key" AS "deviceKey", "output_bytes" AS "outputBytes", "output_messages" AS "outputMessages", "output_revision" AS "outputRevision" FROM "socket_reservations" WHERE "scope_key" = ${this.scopeKey} AND "user_id" = ${userId} ORDER BY "session_id" LIMIT 501`);
  }

  private get(userId: string, sessionId: string): SocketReservation | undefined {
    return this.db.get<SocketReservation>(sql`SELECT "user_id" AS "userId", "team_id" AS "teamId", "session_id" AS "sessionId", "device_key" AS "deviceKey", "output_bytes" AS "outputBytes", "output_messages" AS "outputMessages", "output_revision" AS "outputRevision" FROM "socket_reservations" WHERE "scope_key" = ${this.scopeKey} AND "user_id" = ${userId} AND "session_id" = ${sessionId}`);
  }
}
