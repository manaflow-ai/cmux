// A value-free description of a thrown error for operational telemetry.
//
// Error messages are never exported: a Drizzle query error embeds the SQL and
// its bound parameters, a driver error can embed a connection string, and a
// provider error can echo a credential. What stays is only what code defines:
// the error class names, a Postgres SQLSTATE, a transport errno code, and the
// kind of SQL statement that failed. That is enough to tell a `uuid = text`
// operator mismatch (42883 on a select) from a pool exhaustion or a timeout.

export type SafeErrorCause = {
  /** Class of the thrown error, e.g. `DrizzleQueryError`. */
  readonly errorClass: string;
  /** Class of the innermost distinct cause, e.g. `PostgresError`. */
  readonly causeClass?: string;
  /** Postgres SQLSTATE from any error in the cause chain, e.g. `42883`. */
  readonly dbSqlstate?: string;
  /** Leading keyword of the failed SQL statement, e.g. `select`. */
  readonly dbOperation?: string;
  /** Transport or runtime code, e.g. `ECONNREFUSED`, `UND_ERR_HEADERS_TIMEOUT`. */
  readonly errorCode?: string;
};

const MAX_CAUSE_DEPTH = 8;
const CLASS_NAME = /^[A-Z][A-Za-z0-9]{0,63}$/;
const SQLSTATE = /^[0-9A-Z]{5}$/;
const ERRNO_CODE = /^(?:E[A-Z0-9]{2,30}|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+){1,8})$/;
const SQL_OPERATIONS = new Set([
  "select",
  "insert",
  "update",
  "delete",
  "with",
  "begin",
  "commit",
  "rollback",
  "savepoint",
  "set",
  "lock",
  "copy",
  "call",
  "values",
]);

type MutableCause = {
  causeClass?: string;
  dbSqlstate?: string;
  dbOperation?: string;
  errorCode?: string;
};

export function safeErrorCause(error: unknown): SafeErrorCause {
  if (!(error instanceof Error)) return { errorClass: "NonError" };
  const errorClass = errorClassName(error);
  const found: MutableCause = {};
  const seen = new Set<unknown>();
  let current: unknown = error;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH && current && typeof current === "object"; depth += 1) {
    if (seen.has(current)) break;
    seen.add(current);
    readCauseLink(current, depth > 0 ? errorClass : undefined, found);
    current = (current as { cause?: unknown }).cause;
  }
  return {
    errorClass,
    ...(found.causeClass ? { causeClass: found.causeClass } : {}),
    ...(found.dbSqlstate ? { dbSqlstate: found.dbSqlstate } : {}),
    ...(found.dbOperation ? { dbOperation: found.dbOperation } : {}),
    ...(found.errorCode ? { errorCode: found.errorCode } : {}),
  };
}

/** Folds one link of the cause chain into `found`; the first match wins per field. */
function readCauseLink(link: object, outerClass: string | undefined, found: MutableCause): void {
  const record = link as { code?: unknown; query?: unknown };
  if (outerClass !== undefined && link instanceof Error) {
    const name = errorClassName(link);
    if (name !== outerClass) found.causeClass = name;
  }
  const code = typeof record.code === "string" ? record.code.trim() : "";
  if (code && SQLSTATE.test(code) && /\d/.test(code)) found.dbSqlstate ??= code;
  else if (code && ERRNO_CODE.test(code)) found.errorCode ??= code;
  if (typeof record.query === "string") found.dbOperation ??= sqlOperation(record.query);
}

/**
 * A short, bounded grouping key for a fingerprint: the SQLSTATE when the
 * database answered, else the transport code, else the error class.
 */
export function errorCauseKey(cause: SafeErrorCause): string {
  if (cause.dbSqlstate) return `pg_${cause.dbSqlstate}`;
  if (cause.errorCode) return cause.errorCode;
  return cause.causeClass ?? cause.errorClass;
}

/** `(PostgresError, sqlstate 42883, select)`, or empty when nothing is known. */
export function errorCauseDetail(cause: SafeErrorCause): string {
  const parts = [
    cause.causeClass,
    cause.dbSqlstate ? `sqlstate ${cause.dbSqlstate}` : undefined,
    cause.errorCode,
    cause.dbOperation,
  ].filter((part): part is string => Boolean(part));
  return parts.length > 0 ? ` (${parts.join(", ")})` : "";
}

function errorClassName(error: Error): string {
  // Some library errors never set `name` (Drizzle's query error reports
  // "Error"), so prefer a specific name, then the constructor, then a
  // duck-typed Drizzle query error for minified bundles.
  const name = error.name?.trim();
  if (name && name !== "Error" && CLASS_NAME.test(name)) return name;
  const constructorName = error.constructor?.name;
  if (constructorName && constructorName !== "Error" && CLASS_NAME.test(constructorName)) {
    return constructorName;
  }
  const record = error as { query?: unknown; params?: unknown };
  if (typeof record.query === "string" && Array.isArray(record.params)) return "DrizzleQueryError";
  return "Error";
}

function sqlOperation(query: string): string | undefined {
  const keyword = /^\s*(?:\/\*[\s\S]*?\*\/\s*)*([A-Za-z]+)/.exec(query)?.[1]?.toLowerCase();
  return keyword && SQL_OPERATIONS.has(keyword) ? keyword : undefined;
}
