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

export class VmCreateInProgressError extends Data.TaggedError("VmCreateInProgressError")<{
  readonly idempotencyKey: string;
}> {}

export class VmCreateFailedError extends Data.TaggedError("VmCreateFailedError")<{
  readonly idempotencyKey: string;
  readonly message: string;
}> {}

export class VmCreateDisabledError extends Data.TaggedError("VmCreateDisabledError")<{
  readonly provider?: ProviderId;
  readonly reason: string;
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

export type VmWorkflowError =
  | VmDatabaseError
  | VmProviderOperationError
  | VmNotFoundError
  | VmCreateInProgressError
  | VmCreateFailedError
  | VmCreateDisabledError
  | VmImageConfigError
  | VmLimitExceededError
  | VmCreateCreditsInsufficientError
  | VmBillingError;

export function isVmNotFoundError(err: unknown): err is VmNotFoundError {
  return (err as { _tag?: string } | null)?._tag === "VmNotFoundError";
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
