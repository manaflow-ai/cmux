import { ProviderError } from "./types";

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
