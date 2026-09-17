import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";

import { adminAuditLog } from "../db/schema";
import {
  ADMIN_AUDIT_MAX_LIMIT,
  decodeAuditCursor,
  encodeAuditCursor,
  listAdminAudit,
  parseAuditListQuery,
  recordAdminAudit,
  withAdminAudit,
  type AdminAuditDb,
} from "../services/admin/auditLog";

type StoredRow = Record<string, unknown> & { id: string; createdAt: Date; createdAtText: string };

let inserted: Array<Record<string, unknown>> = [];
let stored: StoredRow[] = [];
let insertFails = false;
let lastLimit: number | null = null;
let lastWhere: unknown = "unset";

function fakeDb(): AdminAuditDb {
  return {
    insert: (table: unknown) => ({
      values: async (values: Record<string, unknown>) => {
        if (table !== adminAuditLog) throw new Error("unexpected table");
        if (insertFails) throw new Error("connection refused");
        inserted.push(values);
      },
    }),
    select: () => ({
      from: () => ({
        where: (clause: unknown) => {
          lastWhere = clause;
          return {
            orderBy: () => ({
              limit: async (limit: number) => {
                lastLimit = limit;
                return stored.slice(0, limit);
              },
            }),
          };
        },
      }),
    }),
  } as unknown as AdminAuditDb;
}

const actor = { id: "admin-1", primaryEmail: "lawrence@manaflow.ai" };
const ID_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ID_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function storedRow(id: string, at: string, overrides: Partial<StoredRow> = {}): StoredRow {
  return {
    id,
    createdAt: new Date(at),
    createdAtText: at.replace("T", " ").replace("Z", "+00"),
    actorUserId: "admin-1",
    actorEmail: "lawrence@manaflow.ai",
    action: "user_grant_set",
    targetKind: "user",
    targetId: "u1",
    targetLabel: null,
    details: { plan: "pro" },
    outcome: "ok",
    error: null,
    ...overrides,
  };
}

describe("admin audit log", () => {
  const consoleError = console.error;
  beforeEach(() => {
    inserted = [];
    stored = [];
    insertFails = false;
    lastLimit = null;
    lastWhere = "unset";
  });
  afterEach(() => {
    console.error = consoleError;
  });

  test("recordAdminAudit writes the actor, target, details, and outcome", async () => {
    await recordAdminAudit({
      actor,
      action: "team_grant_set",
      targetKind: "team",
      targetId: "t1",
      details: { plan: "team" },
      outcome: "ok",
      requestId: "req-1",
      db: fakeDb(),
    });
    expect(inserted).toEqual([{
      actorUserId: "admin-1",
      actorEmail: "lawrence@manaflow.ai",
      action: "team_grant_set",
      targetKind: "team",
      targetId: "t1",
      targetLabel: null,
      details: { plan: "team" },
      outcome: "ok",
      error: null,
      requestId: "req-1",
    }]);
  });

  test("a failed audit write is logged with a stable event and never throws", async () => {
    insertFails = true;
    const logged: unknown[][] = [];
    console.error = (...args: unknown[]) => {
      logged.push(args);
    };
    await recordAdminAudit({ actor, action: "member_invite", targetKind: "admin_member", outcome: "ok", db: fakeDb() });
    expect(inserted).toEqual([]);
    expect(logged).toHaveLength(1);
    expect(logged[0]?.[0]).toBe("admin.audit.write_failed");
    expect(logged[0]?.[1]).toEqual({ action: "member_invite", targetKind: "admin_member", outcome: "ok", cause: "Error" });
  });

  test("withAdminAudit records ok for 2xx and the error code otherwise", async () => {
    const db = fakeDb();
    const entry = { actor, action: "user_grant_set", targetKind: "user", targetId: "u1", db };
    const ok = await withAdminAudit(entry, async () => Response.json({ user: {} }));
    expect(ok.status).toBe(200);
    const notFound = await withAdminAudit(entry, async () =>
      Response.json({ error: "user_not_found" }, { status: 404 }));
    expect(await notFound.json()).toEqual({ error: "user_not_found" });
    await expect(withAdminAudit(entry, async () => {
      throw new TypeError("boom");
    })).rejects.toThrow("boom");
    expect(inserted.map((row) => [row.outcome, row.error])).toEqual([
      ["ok", null],
      ["error", "user_not_found"],
      ["error", "TypeError"],
    ]);
    // The response body is still readable after auditing.
    expect(await ok.json()).toEqual({ user: {} });
  });

  test("a failed audit write does not change the route response", async () => {
    insertFails = true;
    console.error = () => {};
    const response = await withAdminAudit(
      { actor, action: "user_grant_set", targetKind: "user", db: fakeDb() },
      async () => Response.json({ ok: true }),
    );
    expect(response.status).toBe(200);
  });

  test("cursors round-trip and reject garbage", () => {
    const cursor = encodeAuditCursor({ at: "2026-09-09 10:00:00.123456+00", id: ID_A });
    expect(decodeAuditCursor(cursor)).toEqual({ at: "2026-09-09 10:00:00.123456+00", id: ID_A });
    expect(decodeAuditCursor("")).toBeNull();
    expect(decodeAuditCursor("not base64!")).toBeNull();
    expect(decodeAuditCursor(Buffer.from("junk|not-a-uuid").toString("base64url"))).toBeNull();
    expect(decodeAuditCursor(Buffer.from(`1; drop table|${ID_A}`).toString("base64url"))).toBeNull();
  });

  test("parseAuditListQuery defaults, clamps, and rejects bad input", () => {
    expect(parseAuditListQuery({ cursor: null, limit: null })).toEqual({ cursor: null, limit: 50 });
    expect(parseAuditListQuery({ cursor: "", limit: "" })).toEqual({ cursor: null, limit: 50 });
    expect(parseAuditListQuery({ cursor: null, limit: "5000" })).toEqual({ cursor: null, limit: ADMIN_AUDIT_MAX_LIMIT });
    expect(parseAuditListQuery({ cursor: null, limit: "0" })).toBeNull();
    expect(parseAuditListQuery({ cursor: null, limit: "ten" })).toBeNull();
    expect(parseAuditListQuery({ cursor: "nope!", limit: null })).toBeNull();
    const cursor = encodeAuditCursor({ at: "2026-09-09 10:00:00+00", id: ID_A });
    expect(parseAuditListQuery({ cursor, limit: "10" })).toEqual({ cursor, limit: 10 });
  });

  test("listAdminAudit maps rows and hands back a keyset cursor only when more remain", async () => {
    stored = [
      storedRow(ID_B, "2026-09-09T10:00:01.000Z"),
      storedRow(ID_A, "2026-09-09T10:00:00.000Z", { outcome: "error", error: "user_not_found" }),
    ];
    const first = await listAdminAudit({ limit: 1, db: fakeDb() });
    expect(lastLimit).toBe(2);
    expect(lastWhere).toBeUndefined();
    expect(first.rows).toEqual([{
      id: ID_B,
      at: "2026-09-09T10:00:01.000Z",
      actorUserId: "admin-1",
      actorEmail: "lawrence@manaflow.ai",
      action: "user_grant_set",
      targetKind: "user",
      targetId: "u1",
      targetLabel: null,
      details: { plan: "pro" },
      outcome: "ok",
      error: null,
    }]);
    expect(first.nextCursor).toBe(encodeAuditCursor({ at: "2026-09-09 10:00:01.000+00", id: ID_B }));

    stored = [stored[1]!];
    const second = await listAdminAudit({ cursor: first.nextCursor, limit: 1, db: fakeDb() });
    // The keyset predicate is strictly "before the cursor" on (created_at, id),
    // with the cursor's own timestamp and id as the bound parameters.
    const rendered = new PgDialect().sqlToQuery(lastWhere as SQL);
    expect(rendered.sql).toBe(
      '(("admin_audit_log"."created_at" < $1::timestamptz) or ((("admin_audit_log"."created_at" = $2::timestamptz) and ("admin_audit_log"."id" < $3))))',
    );
    expect(rendered.params).toEqual(["2026-09-09 10:00:01.000+00", "2026-09-09 10:00:01.000+00", ID_B]);
    expect(second.rows.map((row) => [row.id, row.outcome, row.error])).toEqual([[ID_A, "error", "user_not_found"]]);
    expect(second.nextCursor).toBeNull();
  });

  test("listAdminAudit clamps the limit and rejects a bad cursor", async () => {
    await listAdminAudit({ limit: 10_000, db: fakeDb() });
    expect(lastLimit).toBe(ADMIN_AUDIT_MAX_LIMIT + 1);
    await expect(listAdminAudit({ cursor: "garbage!", db: fakeDb() })).rejects.toThrow("Invalid audit cursor");
    expect(mock).toBeDefined();
  });
});
