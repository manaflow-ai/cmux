import { DurableObject } from "cloudflare:workers";
import { identifier } from "./contracts/common";
import { environmentScope, type Environment } from "./environment";
import { failureDiagnostics, OperationError, publicError } from "./errors";
import { observe } from "./observability";
import { objectName } from "./routing";
import { applyStorageMigrations } from "./storage/migrations";
import { UserSocketStore } from "./storage/socket-store";
import { UserUsageStore, type UsageOperation } from "./storage/user-usage";
import type { ErrorCode } from "./contracts/responses";

type Result<T> = { ok: true; value: T } | { ok: false; code: ErrorCode; status: number; retryable: boolean; retryAfterMs?: number };
function result<T>(action: () => T, report?: (cause: string) => void): Result<T> {
  try { return { ok: true, value: action() }; }
  catch (error) {
    const failure = publicError(error);
    // The caller only receives the public code across RPC; report the cause here.
    const { cause } = failureDiagnostics(error);
    if (cause) report?.(cause);
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
    return result(() => { this.assertUser(userId); return this.usage.consume(userId, operation); }, this.report("consume"));
  }
  reserveSocket(input: { userId: string; teamId: string; sessionId: string; deviceKey: string }) {
    return result(() => { this.assertUser(input.userId); this.sockets.reserveSocket(input); }, this.report("reserveSocket"));
  }
  setOutput(userId: string, sessionId: string, revision: number, bytes: number, messages: number) {
    return result(() => { this.assertUser(userId); this.sockets.setOutput(userId, sessionId, revision, bytes, messages); }, this.report("setOutput"));
  }
  releaseSocket(userId: string, sessionId: string) {
    return result(() => { this.assertUser(userId); this.sockets.releaseSocket(userId, sessionId); }, this.report("releaseSocket"));
  }
  listSocketReservations(userId: string) {
    return result(() => { this.assertUser(userId); return this.sockets.listSocketReservations(userId); }, this.report("listSocketReservations"));
  }
  private report(operation: string): (cause: string) => void {
    return cause => observe(this.ctx, this.env, { event: "iroh.user_usage.unclassified", environment: this.env.ENVIRONMENT, operation, cause });
  }
  private assertUser(userId: string): void {
    identifier.parse(userId);
    const scope = environmentScope(this.env);
    const expected = this.env.USER_USAGE.idFromName(objectName(scope.environment, scope.projectId, userId));
    if (!this.ctx.id.equals(expected)) throw new OperationError("identity_mismatch", 403);
  }
}
