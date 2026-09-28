import { describe, expect, test } from "bun:test";

import type { AuthedUser } from "../services/vms/auth";
import { billingCatalogTeams } from "../services/billing/teamCatalog";
import { resolveTeamBillingAccess } from "../services/billing/teamBillingAccess";
import { selectedBillingTeamId } from "../services/billing/teamBillingView";
import { parseTeamCatalog } from "../app/[locale]/dashboard/dashboard-team-scope";
import { fixtureStackUser, fixtureTeam } from "./helpers/billing-team-fixtures";

function authedUser(): AuthedUser {
  return {
    id: "user-1",
    displayName: "User One",
    primaryEmail: "user@example.com",
    billingCustomerType: "team",
    billingTeamId: "team-a",
    selectedTeamId: "team-a",
    teams: [
      { id: "team-a", displayName: "Team A", billingPlanId: "team", billingSeats: 5 },
      { id: "team-b", displayName: "Team B", billingPlanId: null, billingSeats: null },
    ],
    teamIds: ["team-a", "team-b"],
    userBillingPlanId: "pro",
    billingPlanId: "team",
    billingSeats: 5,
  };
}

describe("resolveTeamBillingAccess", () => {
  const teamA = fixtureTeam("team-a");
  const user = fixtureStackUser({ id: "user-1", teams: [teamA], adminTeamIds: [] });

  test("members pass without requireAdmin and read as member", async () => {
    expect(await resolveTeamBillingAccess(user, "team-a", { requireAdmin: false })).toMatchObject({
      ok: true,
      role: "member",
      canManageBilling: false,
    });
  });

  test("requireAdmin refuses members; non-members and the personal id are refused before any permission call", async () => {
    expect(await resolveTeamBillingAccess(user, "team-a", { requireAdmin: true })).toEqual({ ok: false, error: "team_admin_required" });
    user.hasPermission.mockClear();
    expect(await resolveTeamBillingAccess(user, "team-z", { requireAdmin: true })).toEqual({ ok: false, error: "team_not_found" });
    expect(await resolveTeamBillingAccess(user, "user-1", { requireAdmin: false })).toEqual({
      ok: false,
      error: "personal_team_not_upgradable_to_team",
    });
    expect(user.hasPermission).not.toHaveBeenCalled();
  });
});

describe("team catalog billing fields", () => {
  test("adds plan, seats and team_admin role per team; personal is admin with the personal plan", async () => {
    const stackUser = fixtureStackUser({
      id: "user-1",
      teams: [fixtureTeam("team-a"), fixtureTeam("team-b")],
      adminTeamIds: ["team-a"],
    });

    const teams = await billingCatalogTeams(authedUser(), async () => stackUser);

    expect(teams.map(({ teamId, planId, seats, role, canManageBilling }) => ({ teamId, planId, seats, role, canManageBilling }))).toEqual([
      { teamId: "team-a", planId: "team", seats: 5, role: "admin", canManageBilling: true },
      { teamId: "team-b", planId: null, seats: null, role: "member", canManageBilling: false },
      { teamId: "user-1", planId: "pro", seats: null, role: "admin", canManageBilling: true },
    ]);
  });

  test("degrades every team to member when Stack cannot load the user", async () => {
    const teams = await billingCatalogTeams(authedUser(), async () => {
      throw new Error("Stack down");
    });

    expect(teams.filter((team) => !team.personal).every((team) => team.role === "member" && !team.canManageBilling)).toBe(true);
  });

  // The real GET /api/subrouter/teams wire shape is covered end to end in
  // hosted-subrouter-routes.test.ts; this checks the dashboard parser keeps it.
  test("the dashboard parser keeps catalog billing fields", async () => {
    const stackUser = fixtureStackUser({ id: "user-1", teams: [fixtureTeam("team-a")], adminTeamIds: ["team-a"] });
    const listTeams = (user: AuthedUser) => billingCatalogTeams(user, async () => stackUser);
    const catalog = {
      selectedTeamId: "team-a",
      teams: (await listTeams(authedUser())).map((team) => ({
        id: team.teamId,
        name: team.teamName,
        personal: team.personal,
        permissions: { use: team.use, manageAccounts: team.manageAccounts },
        planId: team.planId,
        seats: team.seats,
        role: team.role,
        canManageBilling: team.canManageBilling,
      })),
    };
    const parsed = parseTeamCatalog(catalog);

    expect(parsed?.teams[0]).toMatchObject({
      id: "team-a",
      billing: { planId: "team", seats: 5, role: "admin", canManageBilling: true },
    });
    expect(parsed?.teams[1]).toMatchObject({ id: "team-b", billing: { role: "member", canManageBilling: false } });
  });

  test("the parser tolerates catalogs without billing fields and drops malformed ones", () => {
    const parsed = parseTeamCatalog({
      selectedTeamId: null,
      teams: [
        { id: "a", name: "A", personal: false, permissions: { use: true, manageAccounts: true } },
        { id: "b", name: "B", personal: false, permissions: { use: true, manageAccounts: true }, role: "owner", canManageBilling: true, planId: null, seats: null },
      ],
    });

    expect(parsed?.teams).toHaveLength(2);
    expect(parsed?.teams[0].billing).toBeUndefined();
    expect(parsed?.teams[1].billing).toBeUndefined();
  });
});

describe("billing page team selection", () => {
  const base = { userId: "user-1", teamIds: ["team-a", "team-b"], stackSelectedTeamId: "team-a" };

  test("an explicit member ?team= wins, then Stack selection, then personal", () => {
    expect(selectedBillingTeamId({ ...base, requestedTeamId: "team-b" })).toBe("team-b");
    expect(selectedBillingTeamId({ ...base, requestedTeamId: "user-1" })).toBe("user-1");
    expect(selectedBillingTeamId({ ...base, requestedTeamId: "team-x" })).toBe("team-a");
    expect(selectedBillingTeamId({ ...base, requestedTeamId: null, stackSelectedTeamId: null })).toBe("user-1");
  });
});
