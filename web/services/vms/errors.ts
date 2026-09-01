import * as Data from "effect/Data";
import type { ProviderId } from "./drivers";

export class VmDatabaseError extends Data.TaggedError("VmDatabaseError")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class VmProviderOperationError extends Data.TaggedError("VmProviderOperationError")<{
  readonly provider: ProviderId;
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class VmNotFoundError extends Data.TaggedError("VmNotFoundError")<{
  readonly vmId: string;
}> {}

export class VmSnapshotNotFoundError extends Data.TaggedError("VmSnapshotNotFoundError")<{
  readonly snapshotId: string;
}> {}

/** A free-plan machine whose access window has lapsed; upgrading unlocks it. */
export class VmFreeAccessExpiredError extends Data.TaggedError("VmFreeAccessExpiredError")<{
  readonly vmId: string;
  readonly windowDays: number;
}> {}

export class VmCreateInProgressError extends Data.TaggedError("VmCreateInProgressError")<{
  readonly idempotencyKey: string;
}> {}

export class VmCreateFailedError extends Data.TaggedError("VmCreateFailedError")<{
  readonly idempotencyKey: string;
  readonly code: string | null;
  readonly message: string;
}> {}

export class VmCreateDisabledError extends Data.TaggedError("VmCreateDisabledError")<{
  readonly provider?: ProviderId;
  readonly reason: string;
}> {}

export class VmAccountDeletionInProgressError extends Data.TaggedError("VmAccountDeletionInProgressError")<{
  readonly provider?: ProviderId;
  readonly phase?: "create";
}> {}

/**
 * Where the image that failed to resolve came from: the client body, an env
 * selector, or the server's default selection (manifest defaults). The value
 * is returned to clients, so it deliberately avoids implementation wording.
 */
export type VmImageSource = "request" | "env" | "default";

export class VmImageConfigError extends Data.TaggedError("VmImageConfigError")<{
  readonly provider: ProviderId;
  readonly image?: string;
  readonly envVar?: string;
  /** Requested machine kind when the caller asked by kind; kept as a string so bad input is reported verbatim. */
  readonly kind?: string;
  readonly source: VmImageSource;
  /** Manifest image ids for the provider, so the error names what would have worked. */
  readonly allowedImages: readonly string[];
  readonly reason: string;
}> {}

export class VmLimitExceededError extends Data.TaggedError("VmLimitExceededError")<{
  readonly kind: "active_vms";
  readonly billingTeamId: string;
  readonly limit: number;
}> {}

export class VmCreateCreditsInsufficientError extends Data.TaggedError("VmCreateCreditsInsufficientError")<{
  readonly itemId: string;
  readonly billingCustomerId: string;
  readonly amount: number;
}> {}

export class VmBillingError extends Data.TaggedError("VmBillingError")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

/**
 * The caller asked for a session transport the machine's provider does not serve
 * (e.g. the legacy websocket/SSH attach on a Blaxel machine, which only runs the
 * cmux-tui remote daemon). Not retryable: the client must switch transports.
 */
export class VmAttachTransportUnsupportedError extends Data.TaggedError("VmAttachTransportUnsupportedError")<{
  readonly provider: ProviderId;
  readonly vmId: string;
  readonly requested: string;
  readonly supported: readonly string[];
}> {}

export class VmAccountDeletionIdentityRevocationError extends Data.TaggedError(
  "VmAccountDeletionIdentityRevocationError",
)<{
  readonly cause: unknown;
}> {}

export type VmWorkflowError =
  | VmDatabaseError
  | VmProviderOperationError
  | VmNotFoundError
  | VmSnapshotNotFoundError
  | VmFreeAccessExpiredError
  | VmCreateInProgressError
  | VmCreateFailedError
  | VmCreateDisabledError
  | VmAccountDeletionInProgressError
  | VmImageConfigError
  | VmLimitExceededError
  | VmCreateCreditsInsufficientError
  | VmBillingError
  | VmAttachTransportUnsupportedError
  | VmAccountDeletionIdentityRevocationError;

export function isVmNotFoundError(err: unknown): err is VmNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "VmNotFoundError";
}

export function isVmSnapshotNotFoundError(err: unknown): err is VmSnapshotNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "VmSnapshotNotFoundError";
}

export function isVmFreeAccessExpiredError(err: unknown): err is VmFreeAccessExpiredError {
  return (err as { _tag?: string } | null)?._tag === "VmFreeAccessExpiredError";
}

export function isVmCreateInProgressError(err: unknown): err is VmCreateInProgressError {
  return (err as { _tag?: string } | null)?._tag === "VmCreateInProgressError";
}

export function isVmCreateFailedError(err: unknown): err is VmCreateFailedError {
  return (err as { _tag?: string } | null)?._tag === "VmCreateFailedError";
}

export function isVmCreateDisabledError(err: unknown): err is VmCreateDisabledError {
  return (err as { _tag?: string } | null)?._tag === "VmCreateDisabledError";
}

export function isVmAccountDeletionInProgressError(
  err: unknown,
): err is VmAccountDeletionInProgressError {
  return (err as { _tag?: string } | null)?._tag === "VmAccountDeletionInProgressError";
}

export function isVmImageConfigError(err: unknown): err is VmImageConfigError {
  return (err as { _tag?: string } | null)?._tag === "VmImageConfigError";
}

export function isVmLimitExceededError(err: unknown): err is VmLimitExceededError {
  return (err as { _tag?: string } | null)?._tag === "VmLimitExceededError";
}

export function isVmCreateCreditsInsufficientError(err: unknown): err is VmCreateCreditsInsufficientError {
  return (err as { _tag?: string } | null)?._tag === "VmCreateCreditsInsufficientError";
}

export function isVmBillingError(err: unknown): err is VmBillingError {
  return (err as { _tag?: string } | null)?._tag === "VmBillingError";
}

export function isVmAttachTransportUnsupportedError(err: unknown): err is VmAttachTransportUnsupportedError {
  return (err as { _tag?: string } | null)?._tag === "VmAttachTransportUnsupportedError";
}

export function isVmAccountDeletionIdentityRevocationError(
  err: unknown,
): err is VmAccountDeletionIdentityRevocationError {
  return (err as { _tag?: string } | null)?._tag === "VmAccountDeletionIdentityRevocationError";
}

export function isVmDatabaseError(err: unknown): err is VmDatabaseError {
  return (err as { _tag?: string } | null)?._tag === "VmDatabaseError";
}

export function isVmProviderOperationError(err: unknown): err is VmProviderOperationError {
  return (err as { _tag?: string } | null)?._tag === "VmProviderOperationError";
}

const vmWorkflowErrorTags = new Set([
  "VmDatabaseError",
  "VmProviderOperationError",
  "VmNotFoundError",
  "VmFreeAccessExpiredError",
  "VmCreateInProgressError",
  "VmCreateFailedError",
  "VmCreateDisabledError",
  "VmAccountDeletionInProgressError",
  "VmImageConfigError",
  "VmLimitExceededError",
  "VmCreateCreditsInsufficientError",
  "VmBillingError",
  "VmAttachTransportUnsupportedError",
  "VmAccountDeletionIdentityRevocationError",
]);

export function vmWorkflowErrorCause(err: unknown): VmWorkflowError | null {
  if (!err || typeof err !== "object") return null;
  const tag = (err as { _tag?: unknown })._tag;
  if (typeof tag === "string" && vmWorkflowErrorTags.has(tag)) {
    return err as VmWorkflowError;
  }
  const fiberCause = effectFiberFailureCause(err);
  const fiberFailure = vmWorkflowErrorFromEffectCause(fiberCause);
  if (fiberFailure) return fiberFailure;
  const cause = (err as { cause?: unknown }).cause;
  if (cause && cause !== err) return vmWorkflowErrorCause(cause);
  return null;
}

function effectFiberFailureCause(err: object): unknown {
  const symbol = Object.getOwnPropertySymbols(err).find((candidate) =>
    candidate.description === "effect/Runtime/FiberFailure/Cause"
  );
  return symbol ? (err as Record<symbol, unknown>)[symbol] : null;
}

function vmWorkflowErrorFromEffectCause(cause: unknown): VmWorkflowError | null {
  if (!cause || typeof cause !== "object") return null;
  const tag = (cause as { _tag?: unknown })._tag;
  if (tag === "Fail") {
    const failure = (cause as { failure?: unknown; error?: unknown }).failure ??
      (cause as { error?: unknown }).error;
    return vmWorkflowErrorCause(failure);
  }
  if (tag === "Sequential" || tag === "Parallel") {
    return vmWorkflowErrorFromEffectCause((cause as { left?: unknown }).left) ??
      vmWorkflowErrorFromEffectCause((cause as { right?: unknown }).right);
  }
  return vmWorkflowErrorFromEffectCause((cause as { cause?: unknown }).cause);
}
