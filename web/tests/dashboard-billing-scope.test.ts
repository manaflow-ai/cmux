import { describe, expect, mock, test } from "bun:test";
import { call } from "@orpc/server";

const requested: (string | null)[] = [];

mock.module("@/services/billing/dashboardSessionRoute", () => ({
  resolveDashboardSessionUser: async () => ({ ok: true, user: { id: "user-1" } }),
}));
const realBilling = await import("../services/billing/dashboardBilling");
mock.module("@/services/billing/dashboardBilling", () => ({
  ...realBilling,
  loadDashboardBilling: async (_user: unknown, teamId: string | null) => {
    requested.push(teamId);
    return { selectedTeamId: teamId ?? "user-1", personal: null, team: null, teams: [] };
  },
}));

const { accountRouter } = await import("../orpc/server/dashboard/account");
const context = { request: new Request("https://cmux.test/api/dashboard/rpc"), serverPrefetch: true };

describe("Plan & billing scope", () => {
  test("without a team, Plan & billing is the viewer's personal plan, not Stack's selected team", async () => {
    await call(accountRouter.billing, { team: null }, { context });
    await call(accountRouter.billing, { team: "team-9" }, { context });
    expect(requested).toEqual(["user-1", "team-9"]);
  });
});
