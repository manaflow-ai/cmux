import { jsonResponse, vmErrorResponse } from "../vms/routeHelpers";
import {
  RunArtifactConflictError,
  RunAttemptNotFoundError,
  RunIdempotencyConflictError,
  RunLeaseConflictError,
  RunNotFoundError,
  RunPayloadTooLargeError,
  RunEventConflictError,
  RunAttachTicketExpiredError,
  RunAttachTicketNotFoundError,
  RunAttachTicketReplayError,
  RunAttachTargetUnavailableError,
} from "./repository";
import {
  PromotionAlreadyExistsError,
  PromotionIdempotencyConflictError,
  PromotionInProgressError,
  PromotionNotFoundError,
  PromotionNotReadyError,
  PromotionProviderHandlesMissingError,
  PromotionRuntimeUnavailableError,
} from "./promotion";
import { encodeRunCursor, type RunCursor } from "./model";
import { RuntimeAttemptConflictError } from "../vms/runtimeRepository";

/** A client supplied an invalid Run request; keep it in the shared error envelope. */
export class RunRequestError extends Error {
  readonly code: string;
  readonly status: number;
  readonly action: string;
  readonly extra?: Record<string, unknown>;

  constructor(code: string, message: string, action: string, status = 400, extra?: Record<string, unknown>) {
    super(message);
    this.name = "RunRequestError";
    this.code = code;
    this.status = status;
    this.action = action;
    this.extra = extra;
  }
}

/** User sign-in cannot authorize a worker: retain that distinction in recovery guidance. */
export class RunUnauthorizedError extends RunRequestError {
  constructor() {
    super("unauthorized", "This Run attempt request is missing a valid worker credential.",
      "Retry with the worker token issued for this attempt. To view your runs, sign in with `cmux cloud sign-in`; user sign-in does not authorize worker requests.", 401);
  }
}

export function runJson(data: unknown, status = 200): Response {
  return jsonResponse(data, status);
}

export function runError(error: unknown): Response {
  if (error instanceof RunRequestError) {
    return vmErrorResponse({
      error: error.code,
      status: error.status,
      message: error.message,
      action: error.action,
      retryable: false,
      extra: error.extra,
    });
  }
  return runServiceError(error);
}

function runServiceError(error: unknown): Response {
  if (error instanceof RunNotFoundError || error instanceof RunAttemptNotFoundError) {
    return vmErrorResponse({ error: "run_not_found", status: 404, message: "The requested run was not found.", action: "Refresh the run list and retry." });
  }
  if (error instanceof RunIdempotencyConflictError) {
    return vmErrorResponse({ error: "run_idempotency_conflict", status: 409, message: error.message, action: "Retry with the original request or choose a new idempotency key." });
  }
  if (error instanceof RunLeaseConflictError) {
    return vmErrorResponse({ error: "run_lease_conflict", status: 409, message: "That attempt is owned by another live worker.", action: "Retry after the lease expires or use the current worker lease." });
  }
  if (error instanceof RunArtifactConflictError) {
    return vmErrorResponse({ error: "run_artifact_conflict", status: 409, message: error.message, action: "Use a new artifact name or retry with the original manifest." });
  }
  if (error instanceof RunPayloadTooLargeError) {
    return vmErrorResponse({ error: "run_payload_too_large", status: 413, message: error.message, action: "Send a smaller event or artifact manifest." });
  }
  if (error instanceof RunEventConflictError) {
    return vmErrorResponse({ error: "run_event_conflict", status: 409, message: error.message, action: "Retry from the last accepted event sequence." });
  }
  if (error instanceof RunAttachTicketNotFoundError) {
    return vmErrorResponse({ error: "run_attach_ticket_not_found", status: 404, message: "The requested run attach ticket was not found.", action: "Request a new attach ticket and retry." });
  }
  if (error instanceof RunAttachTicketExpiredError) {
    return vmErrorResponse({ error: "run_attach_ticket_expired", status: 410, message: "The retained terminal attach window has expired.", action: "Request a fresh run snapshot and retry attach." });
  }
  if (error instanceof RunAttachTicketReplayError) {
    return vmErrorResponse({ error: "run_attach_ticket_replayed", status: 409, message: "The run attach ticket was already consumed.", action: "Request a new attach ticket and retry." });
  }
  if (error instanceof RunAttachTargetUnavailableError) {
    return vmErrorResponse({ error: "run_attach_target_unavailable", status: 409, message: "This attempt no longer has a retained terminal to attach.", action: "Refresh the run and retry with another attempt." });
  }
  if (error instanceof PromotionNotFoundError) {
    return vmErrorResponse({ error: "run_promotion_not_found", status: 404, message: "The requested run attempt was not found.", action: "Refresh the run list and retry." });
  }
  if (error instanceof PromotionNotReadyError) {
    return vmErrorResponse({ error: "run_promotion_not_ready", status: 409, message: error.message, action: "Wait for a successful attempt with verified evidence, then retry." });
  }
  if (error instanceof PromotionProviderHandlesMissingError) {
    return vmErrorResponse({ error: "run_promotion_provider_handles_missing", status: 409, message: "The winning attempt no longer has the provider handles needed for promotion.", action: "Refresh the run and retry with another attempt." });
  }
  if (error instanceof PromotionAlreadyExistsError) {
    return vmErrorResponse({ error: "run_promotion_duplicate", status: 409, message: "This run attempt has already been promoted.", action: "Use the existing promoted runtime from the original request." });
  }
  if (error instanceof PromotionInProgressError) {
    return vmErrorResponse({ error: "run_promotion_in_progress", status: 409, message: "A promotion for this attempt is already in progress.", action: "Retry with the original Idempotency-Key after the current promotion settles." });
  }
  if (error instanceof PromotionIdempotencyConflictError) {
    return vmErrorResponse({ error: "run_promotion_idempotency_conflict", status: 409, message: error.message, action: "Retry with the original request or choose a new idempotency key." });
  }
  if (error instanceof RuntimeAttemptConflictError) {
    return vmErrorResponse({ error: "run_attempt_conflict", status: 409, message: error.message, action: "Refresh the run and retry against the attempt's current state." });
  }
  if (error instanceof PromotionRuntimeUnavailableError) {
    return vmErrorResponse({ error: "run_promotion_unavailable", status: 503, message: "The persistent runtime service is temporarily unavailable.", action: "Retry in a moment.", retryable: true, retryAfterSeconds: 5 });
  }
  console.error("[runs] route failed", error);
  return vmErrorResponse({ error: "run_unavailable", status: 503, message: "The run service is temporarily unavailable.", action: "Retry in a moment.", retryable: true, retryAfterSeconds: 5 });
}

export function parseCursor(value: string | null): RunCursor | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as RunCursor;
    if (!Number.isSafeInteger(parsed.sequence) || parsed.sequence < 0) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function nextCursor(sequence: number | null): string | null {
  return sequence === null ? null : encodeRunCursor({ sequence });
}

export function jsonBodyObject(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

