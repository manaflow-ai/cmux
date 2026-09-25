import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { coderouterRouteTokens } from "../db/schema";
import { vmToken } from "./vm-authorization-fixture";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
let useStubDb = false;

type Statement = {
  readonly kind: "insert" | "update" | "select";
  readonly table: unknown;
  readonly values: Record<string, unknown>;
  readonly where: SQL | null;
  readonly joins: readonly SQL[];
};
let statements: Statement[] = [];
let returnedRows: Record<string, unknown>[] = [];

function whereResult(rows: Record<string, unknown>[]) {
  return Object.assign(Promise.resolve(rows), {
    returning: async () => rows,
  });
}

const stubDb = {
  select: (fields: Record<string, unknown>) => ({
    from: (table: unknown) => {
      const joins: SQL[] = [];
      const builder = {
        innerJoin: (_joinedTable: unknown, on: SQL) => {
          joins.push(on);
          return builder;
        },
        where: (where: SQL) => ({
          limit: async () => {
            statements.push({ kind: "select", table, values: fields, where, joins });
            return returnedRows;
          },
        }),
      };
      return builder;
    },
  }),
  insert: (table: unknown) => ({
    values: async (values: Record<string, unknown>) => {
      statements.push({ kind: "insert", table, values, where: null, joins: [] });
    },
  }),
  update: (table: unknown) => ({
    set: (values: Record<string, unknown>) => ({
      where: (where: SQL) => {
        statements.push({ kind: "update", table, values, where, joins: [] });
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
  routeTokenLastUsedWritesSettled,
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

  test("a malformed stored VM binding fails closed while CLI tokens still authenticate", async () => {
    returnedRows = [{ id: "token-a", teamId: "team-1", stackUserId: "user-1", vmId: "vm-1" }];
    await expect(authenticateRouteToken(TOKEN)).resolves.toBeNull();
    returnedRows = [{ id: "token-b", teamId: "team-1", stackUserId: "user-1", vmId: null }];
    await expect(authenticateRouteToken(TOKEN)).resolves.toEqual({ teamId: "team-1", stackUserId: "user-1", vmId: null });
    returnedRows = [];
    await expect(authenticateRouteToken(TOKEN)).resolves.toBeNull();
  });

  test("signed VM authorization joins cloud_vms on the uuid claim, never the text binding column", async () => {
    const vmId = "00000000-0000-4000-8000-000000000001";
    const token = await vmToken(vmId, "team-1", "user-1");
    returnedRows = [{ poolId: "pool-1" }];
    await expect(authenticateRouteToken(token)).resolves.toEqual({
      teamId: "team-1",
      stackUserId: "user-1",
      vmId,
      poolId: "pool-1",
    });
    const join = statements[0]?.joins[0];
    expect(join).toBeDefined();
    const joinSql = rendered(join ?? null);
    expect(joinSql.sql).toBe('"cloud_vms"."id" = $1');
    expect(joinSql.params).toEqual([vmId]);
  });

  test("a signed VM claim that is not a uuid fails closed before querying", async () => {
    const token = await vmToken("vm-1", "team-1", "user-1");
    await expect(authenticateRouteToken(token)).resolves.toBeNull();
    expect(statements).toHaveLength(0);
  });

  test("authentication is a read-only lookup and defers a rate-limited last-used write", async () => {
    const now = new Date("2026-09-23T12:00:00.000Z");
    returnedRows = [{ id: "token-c", teamId: "team-1", stackUserId: "user-1", vmId: null }];
    const principals = await Promise.all([
      authenticateRouteToken(TOKEN, now),
      authenticateRouteToken(TOKEN, now),
      authenticateRouteToken(TOKEN, now),
    ]);
    expect(principals.every((principal) => principal?.teamId === "team-1")).toBe(true);
    // Each request only reads; nothing on the request's await chain writes.
    const reads = statements.filter((statement) => statement.kind === "select");
    expect(reads).toHaveLength(3);
    const lookup = rendered(reads[0]?.where ?? null);
    expect(lookup.sql).toContain('"coderouter_route_tokens"."token_hash" = $1');
    expect(lookup.sql).toContain('"coderouter_route_tokens"."revoked_at" is null');

    // One detached write covers all three.
    await routeTokenLastUsedWritesSettled("team-1");
    const writes = statements.filter((statement) => statement.kind === "update");
    expect(writes).toHaveLength(1);
    expect(writes[0]?.table).toBe(coderouterRouteTokens);
    const write = rendered(writes[0]?.where ?? null);
    expect(write.sql).toContain('"coderouter_route_tokens"."id" = $1');
    expect(write.sql).toContain('"coderouter_route_tokens"."last_used_at" <= $2');
    expect(write.params).toEqual(["token-c", new Date("2026-09-23T11:59:00.000Z").toISOString()]);

    // Within the interval, later requests do not write again.
    statements = [];
    await authenticateRouteToken(TOKEN, new Date("2026-09-23T12:00:30.000Z"));
    // A write scheduled by this call would be pending here, so settling waits for it.
    await routeTokenLastUsedWritesSettled("team-1");
    expect(statements.map((statement) => statement.kind)).toEqual(["select"]);
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
