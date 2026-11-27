import * as Data from "effect/Data";

/** Why a hang report body was refused. A fixed code, never body content. */
export type HangReportInvalidReason =
  | "schema"
  | "day_out_of_range"
  | "leak_path"
  | "leak_email"
  | "leak_url"
  | "leak_ip_address"
  | "leak_token";

/** The body is not a valid schema 2 report (HTTP 400; schema 1 included). */
export class HangReportInvalid extends Data.TaggedError("HangReportInvalid")<{
  readonly reason: HangReportInvalidReason;
}> {}

/** This install already stored its reports for the server's UTC day (HTTP 429). */
export class HangReportDailyCapExceeded extends Data.TaggedError("HangReportDailyCapExceeded")<{
  readonly retryAfterSeconds: number;
}> {}

/**
 * The hang report store could not be reached or failed (HTTP 503).
 *
 * Holds only the failed operation, the underlying error's tag or class name,
 * and its Postgres SQLSTATE. The underlying error is dropped on purpose: a
 * drizzle query error's message and fields carry the statement parameters,
 * which are the report payload and the install id.
 */
export class HangReportStorageUnavailable extends Data.TaggedError("HangReportStorageUnavailable")<{
  readonly operation: string;
  readonly causeTag: string;
  readonly sqlstate: string | null;
}> {}

export type HangReportError = HangReportInvalid | HangReportDailyCapExceeded | HangReportStorageUnavailable;

export function isHangReportError(value: unknown): value is HangReportError {
  return value instanceof HangReportInvalid
    || value instanceof HangReportDailyCapExceeded
    || value instanceof HangReportStorageUnavailable;
}

const SQLSTATE = /^[0-9A-Z]{5}$/;
const TAG = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;

/** An error's tag or class name, never its message. */
export function errorTag(error: unknown): string {
  if (error !== null && typeof error === "object") {
    const tag = (error as { _tag?: unknown })._tag;
    if (typeof tag === "string" && TAG.test(tag)) return tag;
    const name = (error as { name?: unknown }).name;
    if (typeof name === "string" && TAG.test(name)) return name;
  }
  return "unknown";
}

/** The first Postgres SQLSTATE along an error's `cause` chain. */
export function sqlstateOf(error: unknown): string | null {
  let current: unknown = error;
  for (let depth = 0; depth < 5 && current !== null && typeof current === "object"; depth += 1) {
    const code = (current as { code?: unknown }).code;
    if (typeof code === "string" && SQLSTATE.test(code)) return code;
    current = (current as { cause?: unknown }).cause;
  }
  return null;
}

/** A ``HangReportStorageUnavailable`` that keeps only the tag and SQLSTATE of `cause`. */
export function storageUnavailable(operation: string, cause: unknown): HangReportStorageUnavailable {
  return new HangReportStorageUnavailable({ operation, causeTag: errorTag(cause), sqlstate: sqlstateOf(cause) });
}

/** The fields safe to log or report for a hang report failure. */
export type HangReportFailureContext = {
  readonly operation: string;
  readonly tag: string;
  readonly sqlstate: string | null;
};
