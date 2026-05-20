import * as Data from "effect/Data";

export class TypefullyDatabaseError extends Data.TaggedError("TypefullyDatabaseError")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class TypefullyDraftNotFoundError extends Data.TaggedError("TypefullyDraftNotFoundError")<{
  readonly draftId: string;
}> {}

export type TypefullyWorkflowError =
  | TypefullyDatabaseError
  | TypefullyDraftNotFoundError;

export function isTypefullyDatabaseError(err: unknown): err is TypefullyDatabaseError {
  return (err as { _tag?: string } | null)?._tag === "TypefullyDatabaseError";
}

export function isTypefullyDraftNotFoundError(err: unknown): err is TypefullyDraftNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "TypefullyDraftNotFoundError";
}

const typefullyWorkflowErrorTags = new Set([
  "TypefullyDatabaseError",
  "TypefullyDraftNotFoundError",
]);

export function typefullyWorkflowErrorCause(err: unknown): TypefullyWorkflowError | null {
  if (!err || typeof err !== "object") return null;
  const tag = (err as { _tag?: unknown })._tag;
  if (typeof tag === "string" && typefullyWorkflowErrorTags.has(tag)) {
    return err as TypefullyWorkflowError;
  }
  const fiberCause = effectFiberFailureCause(err);
  const fiberFailure = typefullyWorkflowErrorFromEffectCause(fiberCause);
  if (fiberFailure) return fiberFailure;
  const cause = (err as { cause?: unknown }).cause;
  if (cause && cause !== err) return typefullyWorkflowErrorCause(cause);
  return null;
}

function effectFiberFailureCause(err: object): unknown {
  const symbol = Object.getOwnPropertySymbols(err).find((candidate) =>
    candidate.description === "effect/Runtime/FiberFailure/Cause"
  );
  return symbol ? (err as Record<symbol, unknown>)[symbol] : null;
}

function typefullyWorkflowErrorFromEffectCause(cause: unknown): TypefullyWorkflowError | null {
  if (!cause || typeof cause !== "object") return null;
  const tag = (cause as { _tag?: unknown })._tag;
  if (tag === "Fail") {
    const failure = (cause as { failure?: unknown; error?: unknown }).failure ??
      (cause as { error?: unknown }).error;
    return typefullyWorkflowErrorCause(failure);
  }
  if (tag === "Sequential" || tag === "Parallel") {
    return typefullyWorkflowErrorFromEffectCause((cause as { left?: unknown }).left) ??
      typefullyWorkflowErrorFromEffectCause((cause as { right?: unknown }).right);
  }
  return typefullyWorkflowErrorFromEffectCause((cause as { cause?: unknown }).cause);
}
