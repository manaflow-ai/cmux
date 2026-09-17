import * as Data from "effect/Data";
import { FiberFailureCauseId } from "effect/Runtime";

export class IrohInvalidInputError extends Data.TaggedError("IrohInvalidInputError")<{
  readonly code: string;
}> {}

export class IrohNotFoundError extends Data.TaggedError("IrohNotFoundError")<{
  readonly resource: "binding" | "challenge";
}> {}

export class IrohForbiddenError extends Data.TaggedError("IrohForbiddenError")<{
  readonly code: string;
}> {}

export class IrohConflictError extends Data.TaggedError("IrohConflictError")<{
  readonly code: string;
}> {}

export class IrohQuotaExceededError extends Data.TaggedError("IrohQuotaExceededError")<{
  readonly code: string;
  readonly retryAfterSeconds: number;
}> {}

export class IrohConfigurationError extends Data.TaggedError("IrohConfigurationError")<{
  readonly component:
    | "grant_signing"
    | "grant_verification"
    | "account_subject"
    | "lan_discovery"
    | "relay_minter";
}> {}

export class IrohDatabaseError extends Data.TaggedError("IrohDatabaseError")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class IrohRelayMintError extends Data.TaggedError("IrohRelayMintError")<{
  readonly code: string;
  readonly cause?: unknown;
}> {}

export type IrohExpectedError =
  | IrohInvalidInputError
  | IrohNotFoundError
  | IrohForbiddenError
  | IrohConflictError
  | IrohQuotaExceededError
  | IrohConfigurationError
  | IrohDatabaseError
  | IrohRelayMintError;

export function irohExpectedError(error: unknown): IrohExpectedError | null {
  if (!error || typeof error !== "object") return null;
  const tag = (error as { _tag?: unknown })._tag;
  if (typeof tag === "string" && IROH_ERROR_TAGS.has(tag)) return error as IrohExpectedError;

  if (FiberFailureCauseId in error) {
    return errorFromCause(
      (error as Record<typeof FiberFailureCauseId, unknown>)[FiberFailureCauseId],
    );
  }
  return null;
}

function errorFromCause(cause: unknown): IrohExpectedError | null {
  if (!cause || typeof cause !== "object") return null;
  const tag = (cause as { _tag?: unknown })._tag;
  if (tag === "Fail") {
    return irohExpectedError(
      (cause as { failure?: unknown; error?: unknown }).failure ??
        (cause as { error?: unknown }).error,
    );
  }
  if (tag === "Sequential" || tag === "Parallel") {
    return errorFromCause((cause as { left?: unknown }).left) ??
      errorFromCause((cause as { right?: unknown }).right);
  }
  return errorFromCause((cause as { cause?: unknown }).cause);
}

const IROH_ERROR_TAGS = new Set([
  "IrohInvalidInputError",
  "IrohNotFoundError",
  "IrohForbiddenError",
  "IrohConflictError",
  "IrohQuotaExceededError",
  "IrohConfigurationError",
  "IrohDatabaseError",
  "IrohRelayMintError",
]);
