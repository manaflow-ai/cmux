import { Effect } from "effect";
import { FreestyleApiError } from "freestyle";
import { ProviderError } from "./types";
import type { FreestyleClientFactory } from "./freestyleGuestCli";

export function isProviderCreateCleanupError(value: unknown): value is ProviderCreateCleanupError {
  return value instanceof ProviderCreateCleanupError;
}

/** Retains the allocation until deletion is confirmed, including both failures. */
export class ProviderCreateCleanupError extends ProviderError {
  readonly name = "ProviderCreateCleanupError";
  constructor(
    readonly providerVmId: string,
    cause: unknown,
    readonly cleanupCause: unknown,
  ) {
    super("freestyle", "create rollback is unconfirmed", cause);
  }
}

export function rollbackFreestyleCreate(client: FreestyleClientFactory, vmId: string, cause: unknown) {
  return Effect.tryPromise({
    try: (signal) => client(15_000, signal).vms.ref(vmId).delete(),
    catch: (cleanupCause) => new ProviderCreateCleanupError(vmId, cause, cleanupCause),
  }).pipe(Effect.catchAll((error) =>
    error.cleanupCause instanceof FreestyleApiError
      && error.cleanupCause.status === 404 && error.cleanupCause.code === "NOT_FOUND"
      ? Effect.void : Effect.fail(error)
  ), Effect.timeoutFail({
    duration: 15_000,
    onTimeout: () => new ProviderCreateCleanupError(vmId, cause, new Error("create rollback deadline")),
  }));
}
