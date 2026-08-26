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

export class VmImageConfigError extends Data.TaggedError("VmImageConfigError")<{
  readonly provider: ProviderId;
  readonly image?: string;
  readonly envVar?: string;
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
  | VmCreateInProgressError
  | VmCreateFailedError
  | VmCreateDisabledError
  | VmAccountDeletionInProgressError
  | VmImageConfigError
  | VmLimitExceededError
  | VmCreateCreditsInsufficientError
  | VmBillingError
  | VmAccountDeletionIdentityRevocationError;

export function isVmNotFoundError(err: unknown): err is VmNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "VmNotFoundError";
}

export function isVmSnapshotNotFoundError(err: unknown): err is VmSnapshotNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "VmSnapshotNotFoundError";
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
  "VmSnapshotNotFoundError",
  "VmCreateInProgressError",
  "VmCreateFailedError",
  "VmCreateDisabledError",
  "VmAccountDeletionInProgressError",
  "VmImageConfigError",
  "VmLimitExceededError",
  "VmCreateCreditsInsufficientError",
  "VmBillingError",
  "VmAccountDeletionIdentityRevocationError",
]);

/**
 * The `runVmWorkflow` boundary (workflows.ts) unwraps Effect exits with
 * `Effect.runPromiseExit` + `Cause.failureOption`, so a rejected workflow
 * promise is always the tagged error itself — never a FiberFailure wrapper.
 * This guard is for boundaries that receive `unknown` (route catch blocks).
 */
export function isVmWorkflowError(err: unknown): err is VmWorkflowError {
  if (!err || typeof err !== "object") return false;
  const tag = (err as { _tag?: unknown })._tag;
  return typeof tag === "string" && vmWorkflowErrorTags.has(tag);
}
