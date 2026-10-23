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

/** The body is not a valid schema 1 report (HTTP 400). */
export class HangReportInvalid extends Data.TaggedError("HangReportInvalid")<{
  readonly reason: HangReportInvalidReason;
}> {}

/** This install already stored its reports for the server's UTC day (HTTP 429). */
export class HangReportDailyCapExceeded extends Data.TaggedError("HangReportDailyCapExceeded")<{
  readonly retryAfterSeconds: number;
}> {}

/** The hang report store could not be reached or failed (HTTP 503). */
export class HangReportStorageUnavailable extends Data.TaggedError("HangReportStorageUnavailable")<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export type HangReportError = HangReportInvalid | HangReportDailyCapExceeded | HangReportStorageUnavailable;

export function isHangReportError(value: unknown): value is HangReportError {
  return value instanceof HangReportInvalid
    || value instanceof HangReportDailyCapExceeded
    || value instanceof HangReportStorageUnavailable;
}
