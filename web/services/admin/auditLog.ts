// Admin audit log.
//
// Every admin mutation route records one row: who acted, what they targeted,
// the request details, and the outcome. A failed audit write is reported with
// a stable console event and never changes the route's response.

import { and, desc, eq, lt, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminAuditLog } from "../../db/schema";

export type AdminAuditOutcome = "ok" | "error";

export type AdminAuditDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert">;

export type AdminAuditActor = {
  readonly id: string;
  readonly primaryEmail?: string | null;
};

export type AdminAuditEntry = {
  readonly actor: AdminAuditActor;
  /** Stable snake_case name, e.g. user_grant_set. */
  readonly action: string;
  readonly targetKind: string;
  readonly targetId?: string | null;
  readonly targetLabel?: string | null;
  readonly details?: Record<string, unknown> | null;
  readonly requestId?: string | null;
};

export type RecordAdminAuditInput = AdminAuditEntry & {
  readonly outcome: AdminAuditOutcome;
  readonly error?: string | null;
  readonly db?: AdminAuditDb;
};

export type AdminAuditRow = {
  readonly id: string;
  /** ISO timestamp. */
  readonly at: string;
  readonly actorUserId: string;
  readonly actorEmail: string | null;
  readonly action: string;
  readonly targetKind: string;
  readonly targetId: string | null;
  readonly targetLabel: string | null;
  readonly details: unknown;
  readonly outcome: AdminAuditOutcome;
  readonly error: string | null;
};

export type AdminAuditPage = {
  readonly rows: AdminAuditRow[];
  readonly nextCursor: string | null;
};

export const ADMIN_AUDIT_DEFAULT_LIMIT = 50;
export const ADMIN_AUDIT_MAX_LIMIT = 200;

const AUDIT_WRITE_FAILED_EVENT = "admin.audit.write_failed";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Writes one audit row. Never throws: a lost audit row is logged, not surfaced. */
export async function recordAdminAudit(input: RecordAdminAuditInput): Promise<void> {
  try {
    const db = input.db ?? cloudDb();
    await db.insert(adminAuditLog).values({
      actorUserId: input.actor.id,
      actorEmail: input.actor.primaryEmail ?? null,
      action: input.action,
      targetKind: input.targetKind,
      targetId: input.targetId ?? null,
      targetLabel: input.targetLabel ?? null,
      details: input.details ?? null,
      outcome: input.outcome,
      error: input.error ?? null,
      requestId: input.requestId ?? null,
    });
  } catch (error) {
    // No identifiers or raw database text in the log line: the row that was
    // lost is described by its shape only.
    console.error(AUDIT_WRITE_FAILED_EVENT, {
      action: input.action,
      targetKind: input.targetKind,
      outcome: input.outcome,
      cause: errorCodeForThrown(error),
    });
  }
}

/**
 * Runs an admin mutation and records its outcome from the response: 2xx is
 * `ok`, anything else is `error` with the JSON `error` code. A thrown defect is
 * recorded as `error` with the error name and then rethrown.
 */
export async function withAdminAudit(
  entry: AdminAuditEntry & { readonly db?: AdminAuditDb },
  run: () => Promise<Response>,
): Promise<Response> {
  let response: Response;
  try {
    response = await run();
  } catch (error) {
    await recordAdminAudit({ ...entry, outcome: "error", error: errorCodeForThrown(error) });
    throw error;
  }
  const error = response.ok ? null : await responseErrorCode(response);
  await recordAdminAudit({ ...entry, outcome: response.ok ? "ok" : "error", error });
  return response;
}

/** Vercel stamps every request with x-vercel-id; other hosts may set x-request-id. */
export function auditRequestId(request: Request): string | null {
  return request.headers.get("x-vercel-id") ?? request.headers.get("x-request-id");
}

function errorCodeForThrown(error: unknown): string {
  if (error instanceof Error) return error.name || "Error";
  return "unknown";
}

async function responseErrorCode(response: Response): Promise<string> {
  try {
    const body = (await response.clone().json()) as { error?: unknown };
    if (body && typeof body === "object" && typeof body.error === "string") return body.error;
  } catch {
    // Non-JSON error body: the status is the only code we have.
  }
  return `http_${response.status}`;
}

// ---------------------------------------------------------------------------
// Listing

type AuditCursor = { readonly at: string; readonly id: string };

/**
 * Cursor = base64url of `<created_at as Postgres text>|<id>`. The Postgres
 * text form keeps microseconds, so the keyset compare never skips rows that
 * share a millisecond with the cursor.
 */
export function encodeAuditCursor(cursor: AuditCursor): string {
  return Buffer.from(`${cursor.at}|${cursor.id}`, "utf8").toString("base64url");
}

export function decodeAuditCursor(value: string): AuditCursor | null {
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(value)) return null;
  const decoded = Buffer.from(value, "base64url").toString("utf8");
  const separator = decoded.lastIndexOf("|");
  if (separator <= 0) return null;
  const at = decoded.slice(0, separator);
  const id = decoded.slice(separator + 1);
  if (!UUID_PATTERN.test(id)) return null;
  if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,6})?[+-]\d{2}(:\d{2})?$/.test(at)) return null;
  return { at, id };
}

/** Parses `?cursor=&limit=` for the list route; null means the query is invalid. */
export function parseAuditListQuery(params: {
  readonly cursor: string | null;
  readonly limit: string | null;
}): { cursor: string | null; limit: number } | null {
  const cursor = params.cursor === null || params.cursor === "" ? null : params.cursor;
  if (cursor !== null && decodeAuditCursor(cursor) === null) return null;
  if (params.limit === null || params.limit === "") {
    return { cursor, limit: ADMIN_AUDIT_DEFAULT_LIMIT };
  }
  if (!/^\d{1,4}$/.test(params.limit)) return null;
  const limit = Number(params.limit);
  if (limit < 1) return null;
  return { cursor, limit: Math.min(limit, ADMIN_AUDIT_MAX_LIMIT) };
}

export async function listAdminAudit(input: {
  readonly cursor?: string | null;
  readonly limit?: number;
  readonly db?: AdminAuditDb;
}): Promise<AdminAuditPage> {
  const limit = Math.min(Math.max(input.limit ?? ADMIN_AUDIT_DEFAULT_LIMIT, 1), ADMIN_AUDIT_MAX_LIMIT);
  const cursor = input.cursor ? decodeAuditCursor(input.cursor) : null;
  if (input.cursor && !cursor) throw new AdminAuditInvalidCursorError();
  const db = input.db ?? cloudDb();
  const createdAtText = sql<string>`${adminAuditLog.createdAt}::text`;
  const rows = await db
    .select({
      id: adminAuditLog.id,
      createdAt: adminAuditLog.createdAt,
      createdAtText,
      actorUserId: adminAuditLog.actorUserId,
      actorEmail: adminAuditLog.actorEmail,
      action: adminAuditLog.action,
      targetKind: adminAuditLog.targetKind,
      targetId: adminAuditLog.targetId,
      targetLabel: adminAuditLog.targetLabel,
      details: adminAuditLog.details,
      outcome: adminAuditLog.outcome,
      error: adminAuditLog.error,
    })
    .from(adminAuditLog)
    .where(cursor ? keysetBefore(cursor) : undefined)
    .orderBy(desc(adminAuditLog.createdAt), desc(adminAuditLog.id))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const last = rows.length > limit ? page[page.length - 1] : undefined;
  return {
    rows: page.map((row) => ({
      id: row.id,
      at: row.createdAt.toISOString(),
      actorUserId: row.actorUserId,
      actorEmail: row.actorEmail ?? null,
      action: row.action,
      targetKind: row.targetKind,
      targetId: row.targetId ?? null,
      targetLabel: row.targetLabel ?? null,
      details: row.details ?? null,
      outcome: row.outcome === "error" ? "error" : "ok",
      error: row.error ?? null,
    })),
    nextCursor: last ? encodeAuditCursor({ at: last.createdAtText, id: last.id }) : null,
  };
}

function keysetBefore(cursor: AuditCursor) {
  const at = sql`${cursor.at}::timestamptz`;
  return or(
    lt(adminAuditLog.createdAt, at),
    and(eq(adminAuditLog.createdAt, at), lt(adminAuditLog.id, cursor.id)),
  );
}

export class AdminAuditInvalidCursorError extends Error {
  constructor() {
    super("Invalid audit cursor");
    this.name = "AdminAuditInvalidCursorError";
  }
}
