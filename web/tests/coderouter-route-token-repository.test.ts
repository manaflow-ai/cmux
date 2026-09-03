import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { coderouterRouteTokens } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
let useStubDb = false;

type Statement = {
  readonly kind: "insert" | "update";
  readonly table: unknown;
  readonly values: Record<string, unknown>;
  readonly where: SQL | null;
};
let statements: Statement[] = [];
let returnedRows: Record<string, unknown>[] = [];

function whereResult(rows: Record<string, unknown>[]) {
  return Object.assign(Promise.resolve(rows), {
    returning: async () => rows,
  });
}

const stubDb = {
  insert: (table: unknown) => ({
    values: async (values: Record<string, unknown>) => {
      statements.push({ kind: "insert", table, values, where: null });
    },
  }),
  update: (table: unknown) => ({
    set: (values: Record<string, unknown>) => ({
      where: (where: SQL) => {
        statements.push({ kind: "update", table, values, where });
        return whereResult(returnedRows);
      },
    }),
  }),
};

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => (useStubDb ? stubDb : realCloudDb()),
}));

const {
  authenticateRouteToken,
  bindRouteTokenToVm,
  issueRouteToken,
  revokeRouteTokensForVm,
  routeTokenHash,
} = await import("../services/coderouter/repository");

beforeAll(() => {
  useStubDb = true;
});
afterAll(() => {
  useStubDb = false;
});
beforeEach(() => {
  statements = [];
  returnedRows = [];
});

const dialect = new PgDialect();
function rendered(where: SQL | null): { sql: string; params: unknown[] } {
  if (!where) throw new Error("statement had no where clause");
  const query = dialect.sqlToQuery(where);
  return { sql: query.sql, params: query.params };
}

const TOKEN = `crt_${"a".repeat(43)}`;

describe("coderouter route token VM binding", () => {
  test("issueRouteToken stores the VM binding when given one", async () => {
    await issueRouteToken("team-1", "user-1", "vm", { vmId: "vm-1" });
    await issueRouteToken("team-1", "user-1");
    expect(statements).toHaveLength(2);
    expect(statements[0]?.table).toBe(coderouterRouteTokens);
    expect(statements[0]?.values).toMatchObject({
      teamId: "team-1",
      stackUserId: "user-1",
      label: "vm",
      vmId: "vm-1",
    });
    expect(statements[1]?.values).toMatchObject({ label: "cli", vmId: null });
  });

  test("authenticateRouteToken returns the binding", async () => {
    returnedRows = [{ teamId: "team-1", stackUserId: "user-1", vmId: "vm-1" }];
    await expect(authenticateRouteToken(TOKEN)).resolves.toEqual({
      teamId: "team-1",
      stackUserId: "user-1",
      vmId: "vm-1",
    });
    returnedRows = [{ teamId: "team-1", stackUserId: "user-1", vmId: null }];
    await expect(authenticateRouteToken(TOKEN)).resolves.toMatchObject({ vmId: null });
    returnedRows = [];
    await expect(authenticateRouteToken(TOKEN)).resolves.toBeNull();
  });

  test("bindRouteTokenToVm only claims an unbound, live token of the team", async () => {
    returnedRows = [{ id: "row-1" }];
    await expect(bindRouteTokenToVm("team-1", TOKEN, "vm-1")).resolves.toBe(true);
    const [statement] = statements;
    expect(statement?.kind).toBe("update");
    expect(statement?.table).toBe(coderouterRouteTokens);
    expect(statement?.values).toEqual({ vmId: "vm-1" });
    const { sql, params } = rendered(statement?.where ?? null);
    expect(sql).toContain('"coderouter_route_tokens"."team_id" = $1');
    expect(sql).toContain('"coderouter_route_tokens"."token_hash" = $2');
    expect(sql).toContain('"coderouter_route_tokens"."vm_id" is null');
    expect(sql).toContain('"coderouter_route_tokens"."revoked_at" is null');
    expect(params).toEqual(["team-1", routeTokenHash(TOKEN)]);
  });

  test("bindRouteTokenToVm reports false when nothing was bound", async () => {
    returnedRows = [];
    await expect(bindRouteTokenToVm("team-1", TOKEN, "vm-1")).resolves.toBe(false);
    expect(statements).toHaveLength(1);
  });

  test("bindRouteTokenToVm rejects malformed tokens without a query", async () => {
    await expect(bindRouteTokenToVm("team-1", "not-a-token", "vm-1")).resolves.toBe(false);
    await expect(bindRouteTokenToVm("team-1", "crt_short", "vm-1")).resolves.toBe(false);
    expect(statements).toHaveLength(0);
  });

  test("revokeRouteTokensForVm revokes only that VM's live tokens", async () => {
    const now = new Date("2026-09-02T10:00:00.000Z");
    await revokeRouteTokensForVm("vm-1", now);
    const [statement] = statements;
    expect(statement?.kind).toBe("update");
    expect(statement?.values).toEqual({ revokedAt: now });
    const { sql, params } = rendered(statement?.where ?? null);
    expect(sql).toContain('"coderouter_route_tokens"."vm_id" = $1');
    expect(sql).toContain('"coderouter_route_tokens"."revoked_at" is null');
    expect(params).toEqual(["vm-1"]);
  });
});
