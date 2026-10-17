import { describe, expect, mock, test } from "bun:test";
import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";

// Every team-subscription read must see Team Max rows: the seat reconciler,
// the team billing panel, and the team plan status. The predicates are
// rendered to SQL so the test checks what the database is asked for.
const dbClientModule = await import("../db/client");
const predicates: SQL[] = [];
let rows: Array<Record<string, unknown>> = [];

function chain(): Record<string, unknown> {
  const result: Record<string, unknown> = {
    then: (resolve: (value: unknown) => unknown, reject?: (error: unknown) => unknown) =>
      Promise.resolve(rows).then(resolve, reject),
    where: (predicate: SQL) => {
      predicates.push(predicate);
      return chain();
    },
    orderBy: () => chain(),
    limit: async () => rows,
  };
  return result;
}

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => ({ select: () => ({ from: () => chain() }) }),
}));

const { activeTeamSubscriptionRow } = await import("../services/billing/teamSeats");
const { latestActiveTeamSubscription } = await import("../services/billing/teamBillingView");
const { activeTeamPlanIdForTeam } = await import("../services/billing/pro");

function lastQueryParams(): unknown[] {
  const predicate = predicates.at(-1);
  if (!predicate) throw new Error("no query was made");
  return new PgDialect().sqlToQuery(predicate).params;
}

describe("team subscription queries include Team Max", () => {
  test("the seat reconciler reads Team and Team Max rows", async () => {
    rows = [{ id: "sub_team", seats: 3 }];
    expect(await activeTeamSubscriptionRow("team-1")).toEqual({ id: "sub_team", seats: 3 });
    const params = lastQueryParams();
    expect(params).toContain("team");
    expect(params).toContain("team_max");
  });

  test("the team billing panel reads Team and Team Max rows", async () => {
    rows = [];
    await latestActiveTeamSubscription("team-1");
    expect(lastQueryParams()).toContain("team_max");
  });

  test("the team plan status reports the active row's plan", async () => {
    rows = [{ id: "sub_team", plan: "team_max" }];
    expect(await activeTeamPlanIdForTeam("team-1")).toBe("team_max");
    expect(lastQueryParams()).toContain("team_max");
    rows = [{ id: "sub_team", plan: "team" }];
    expect(await activeTeamPlanIdForTeam("team-1")).toBe("team");
    rows = [];
    expect(await activeTeamPlanIdForTeam("team-1")).toBeNull();
  });
});
