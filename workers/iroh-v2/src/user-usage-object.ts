import { DurableObject } from "cloudflare:workers";
import { identifier } from "./contracts/common";
import { environmentScope, type Environment } from "./environment";
import { OperationError, publicError } from "./errors";
import { objectName } from "./routing";
import { applyStorageMigrations } from "./storage/migrations";
import { UserSocketStore } from "./storage/socket-store";
import { UserUsageStore, type UsageOperation } from "./storage/user-usage";
import type { ErrorCode } from "./contracts/responses";

type Result<T> = { ok: true; value: T } | { ok: false; code: ErrorCode; status: number; retryable: boolean; retryAfterMs?: number };
function result<T>(action: () => T): Result<T> {
  try { return { ok: true, value: action() }; }
  catch (error) {
    const failure = publicError(error);
    return { ok: false, code: failure.code, status: failure.status, retryable: failure.retryable,
      ...(failure.retryAfterMs === undefined ? {} : { retryAfterMs: failure.retryAfterMs }) };
  }
}
export function unwrap<T>(value: Result<T>): T {
  if (!value.ok) throw new OperationError(value.code, value.status, value.retryable, value.retryAfterMs);
  return value.value;
}

/** Private RPC object shared by all of a verified user's teams in this environment. */
export class UserUsage extends DurableObject<Environment> {
  private readonly usage;
  private readonly sockets;
  constructor(ctx: DurableObjectState, env: Environment) {
    super(ctx, env);
    const scope = environmentScope(env);
    this.usage = new UserUsageStore(ctx.storage, scope, { initialize: false });
    this.sockets = new UserSocketStore(ctx.storage, scope, { initialize: false });
    ctx.blockConcurrencyWhile(async () => { applyStorageMigrations(ctx.storage); });
  }

  consume(userId: string, operation: UsageOperation) {
    return result(() => { this.assertUser(userId); return this.usage.consume(userId, operation); });
  }
  reserveSocket(input: { userId: string; teamId: string; sessionId: string; deviceKey: string }) {
    return result(() => { this.assertUser(input.userId); this.sockets.reserveSocket(input); });
  }
  setOutput(userId: string, sessionId: string, revision: number, bytes: number, messages: number) {
    return result(() => { this.assertUser(userId); this.sockets.setOutput(userId, sessionId, revision, bytes, messages); });
  }
  releaseSocket(userId: string, sessionId: string) {
    return result(() => { this.assertUser(userId); this.sockets.releaseSocket(userId, sessionId); });
  }
  listSocketReservations(userId: string) {
    return result(() => { this.assertUser(userId); return this.sockets.listSocketReservations(userId); });
  }
  private assertUser(userId: string): void {
    identifier.parse(userId);
    const scope = environmentScope(this.env);
    const expected = this.env.USER_USAGE.idFromName(objectName(scope.environment, scope.projectId, userId));
    if (!this.ctx.id.equals(expected)) throw new OperationError("identity_mismatch", 403);
  }
}
