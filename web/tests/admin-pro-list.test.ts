import { describe, expect, test } from "bun:test";

import {
  isValidScanCursor,
  listAllPendingEmailGrants,
  mapWithConcurrency,
  PRO_LIST_MAX_ROWS,
  listStripeProSubscribers,
  listStripeTeamSubscriptions,
  scanManualTeamGrants,
  scanManualUserGrants,
  type ProListDb,
  type ProListStackApp,
} from "../services/admin/proList";
import { adminPlanGrants, stripeSubscriptions } from "../db/schema";

/** Chainable select double: from(table) picks the row set; joins/where/order are ignored. */
function fakeDb(rowsByTable: Map<unknown, unknown[]>): ProListDb {
  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = rowsByTable.get(table) ?? [];
        const chain = {
          leftJoin: () => chain,
          where: () => chain,
          orderBy: () => chain,
          limit: async () => rows,
        };
        return chain;
      },
    }),
  } as unknown as ProListDb;
}

function fakeApp(input: {
  users?: Array<Record<string, unknown>>;
  teams?: Array<Record<string, unknown>>;
  pageSize?: number;
}): ProListStackApp & { calls: unknown[] } {
  const calls: unknown[] = [];
  const page = <T,>(all: T[], options: { cursor?: string; limit?: number }) => {
    const start = options.cursor ? Number(options.cursor) : 0;
    const limit = options.limit ?? 100;
    const slice = all.slice(start, start + limit);
    const next = start + limit < all.length ? String(start + limit) : null;
    return Object.assign(slice, { nextCursor: next });
  };
  return {
    calls,
    async getTeam(teamId) {
      const team = (input.teams ?? []).find((candidate) => candidate.id === teamId);
      return team ? { id: teamId, displayName: String(team.displayName) } : null;
    },
    async listUsers(options) {
      calls.push({ kind: "users", ...options });
      return page(input.users ?? [], options) as never;
    },
    async listTeams(options) {
      calls.push({ kind: "teams", ...options });
      return page(input.teams ?? [], options) as never;
    },
  };
}

describe("Pro roster", () => {
  test("lists one Stripe subscriber per user with the customer email", async () => {
    const db = fakeDb(new Map([[stripeSubscriptions, [
      { userId: "u1", subscriptionId: "sub_new", status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: new Date("2026-10-01T00:00:00Z"), email: "pat@example.com" },
      { userId: "u1", subscriptionId: "sub_old", status: "past_due", cancelAtPeriodEnd: true, currentPeriodEnd: new Date("2026-09-01T00:00:00Z"), email: "pat@example.com" },
      { userId: "u2", subscriptionId: "sub_2", status: "trialing", cancelAtPeriodEnd: false, currentPeriodEnd: null, email: null },
    ]]]));
    const { rows, truncated } = await listStripeProSubscribers({ db });
    expect(truncated).toBe(false);
    expect(rows).toEqual([
      { userId: "u1", email: "pat@example.com", subscriptionId: "sub_new", status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: "2026-10-01T00:00:00.000Z" },
      { userId: "u2", email: null, subscriptionId: "sub_2", status: "trialing", cancelAtPeriodEnd: false, currentPeriodEnd: null },
    ]);
  });

  test("lists team subscriptions with the Stack display name when reachable", async () => {
    const db = fakeDb(new Map([[stripeSubscriptions, [
      { teamId: "t1", subscriptionId: "sub_t1", status: "active", seats: 5, cancelAtPeriodEnd: false, currentPeriodEnd: null },
      { teamId: "t1", subscriptionId: "sub_t1_dup", status: "active", seats: 5, cancelAtPeriodEnd: false, currentPeriodEnd: null },
      { teamId: "t9", subscriptionId: "sub_t9", status: "active", seats: null, cancelAtPeriodEnd: true, currentPeriodEnd: null },
    ]]]));
    const app = fakeApp({ teams: [{ id: "t1", displayName: "Acme" }] });
    const { rows } = await listStripeTeamSubscriptions({ db, app });
    expect(rows.map((row) => [row.teamId, row.displayName, row.seats, row.cancelAtPeriodEnd])).toEqual([
      ["t1", "Acme", 5, false],
      ["t9", null, null, true],
    ]);
  });

  test("lists open pending grants", async () => {
    const db = fakeDb(new Map([[adminPlanGrants, [
      { id: "g1", email: "a@example.com", plan: "pro", grantedByEmail: "lawrence@manaflow.ai", createdAt: new Date("2026-09-02T00:00:00Z") },
    ]]]));
    expect(await listAllPendingEmailGrants({ db })).toEqual({
      truncated: false,
      rows: [
        { id: "g1", email: "a@example.com", plan: "pro", grantedByEmail: "lawrence@manaflow.ai", createdAt: "2026-09-02T00:00:00.000Z" },
      ],
    });
  });

  test("scans the user directory page by page and keeps only paid manual overrides", async () => {
    const users = [
      { id: "u1", primaryEmail: "a@example.com", primaryEmailVerified: true, isAnonymous: false, clientReadOnlyMetadata: { cmuxVmPlan: "pro" }, serverMetadata: { cmuxAdminPlanGrant: { plan: "pro", byUserId: "admin-1", byEmail: "lawrence@manaflow.ai", at: "2026-09-02T00:00:00.000Z" } } },
      { id: "u2", primaryEmail: "b@example.com", primaryEmailVerified: true, isAnonymous: false, clientReadOnlyMetadata: { cmuxPlan: "pro" }, serverMetadata: {} },
      { id: "u3", primaryEmail: "c@example.com", primaryEmailVerified: false, isAnonymous: false, clientReadOnlyMetadata: { cmuxVmPlan: "free" }, serverMetadata: {} },
      { id: "u4", primaryEmail: "d@example.com", primaryEmailVerified: false, isAnonymous: false, clientReadOnlyMetadata: { cmuxVmPlan: "Founders" }, serverMetadata: {} },
      { id: "u5", primaryEmail: "anon@example.com", primaryEmailVerified: true, isAnonymous: true, clientReadOnlyMetadata: { cmuxVmPlan: "pro" }, serverMetadata: {} },
    ];
    const app = fakeApp({ users });
    const first = await scanManualUserGrants(null, { app, pageSize: 3 });
    expect(first.scanned).toBe(3);
    expect(first.nextCursor).toBe("3");
    expect(first.rows.map((row) => [row.userId, row.plan, row.lastGrant?.byEmail ?? null])).toEqual([["u1", "pro", "lawrence@manaflow.ai"]]);
    const second = await scanManualUserGrants(first.nextCursor, { app, pageSize: 3 });
    expect(second.scanned).toBe(2);
    expect(second.nextCursor).toBeNull();
    expect(second.rows.map((row) => [row.userId, row.plan, row.emailVerified])).toEqual([["u4", "founders", false]]);
    expect(app.calls).toEqual([
      { kind: "users", cursor: undefined, limit: 3, includeAnonymous: false, includeRestricted: true },
      { kind: "users", cursor: "3", limit: 3, includeAnonymous: false, includeRestricted: true },
    ]);
  });

  test("scans teams for paid manual overrides", async () => {
    const app = fakeApp({ teams: [
      { id: "t1", displayName: "Acme", clientReadOnlyMetadata: { cmuxVmPlan: "team" }, serverMetadata: {} },
      { id: "t2", displayName: "Free", clientReadOnlyMetadata: { cmuxPlan: "team" }, serverMetadata: {} },
    ] });
    const page = await scanManualTeamGrants(null, { app });
    expect(page.rows.map((row) => [row.teamId, row.plan])).toEqual([["t1", "team"]]);
    expect(page.nextCursor).toBeNull();
  });

  test("reports truncation when a source exceeds the row cap", async () => {
    const many = Array.from({ length: PRO_LIST_MAX_ROWS + 1 }, (_, i) => ({
      userId: `u${i}`, subscriptionId: `sub_${i}`, status: "active", cancelAtPeriodEnd: false, currentPeriodEnd: null, email: null,
    }));
    const { rows, truncated } = await listStripeProSubscribers({ db: fakeDb(new Map([[stripeSubscriptions, many]])) });
    expect(truncated).toBe(true);
    expect(rows).toHaveLength(PRO_LIST_MAX_ROWS);
  });

  test("team name lookups run with bounded concurrency", async () => {
    const subs = Array.from({ length: 20 }, (_, i) => ({
      teamId: `t${i}`, subscriptionId: `sub_${i}`, status: "active", seats: 1, cancelAtPeriodEnd: false, currentPeriodEnd: null,
    }));
    let inFlight = 0; let peak = 0;
    const app: ProListStackApp = {
      async getTeam(teamId) {
        inFlight += 1; peak = Math.max(peak, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 2));
        inFlight -= 1;
        return { id: teamId, displayName: `Team ${teamId}` };
      },
      listUsers: async () => Object.assign([], { nextCursor: null }) as never,
      listTeams: async () => Object.assign([], { nextCursor: null }) as never,
    };
    const { rows } = await listStripeTeamSubscriptions({ db: fakeDb(new Map([[stripeSubscriptions, subs]])), app, concurrency: 4 });
    expect(rows.map((row) => row.displayName)).toEqual(subs.map((sub) => `Team ${sub.teamId}`));
    expect(peak).toBeLessThanOrEqual(4);
    expect(await mapWithConcurrency([], 3, async () => 1)).toEqual([]);
  });

  test("isValidScanCursor accepts opaque tokens and rejects junk", () => {
    expect(isValidScanCursor("abc123")).toBe(true);
    expect(isValidScanCursor("eyJhIjoxfQ==")).toBe(true);
    expect(isValidScanCursor("")).toBe(false);
    expect(isValidScanCursor("a b")).toBe(false);
    expect(isValidScanCursor("<script>")).toBe(false);
    expect(isValidScanCursor("x".repeat(600))).toBe(false);
  });
});
