import { describe, expect, mock, test } from "bun:test";

import { makeCoderouterTransferHandler, transferDestinationTeams } from "../app/api/coderouter/accounts/[accountId]/transfer/route";
import type { AuthedUser } from "../services/vms/auth";

const ACCOUNT_ID = "00000000-0000-4000-8000-000000000001";
const context = {
  ok: true as const,
  value: {
    user: { id: "user-1" },
    team: {
      teamId: "team-source",
      teamName: "Source",
      use: true,
      manageAccounts: true,
    },
  },
};

const teams = [
  {
    teamId: "team-source",
    teamName: "Source",
    use: true,
    manageAccounts: true,
    personal: false,
  },
  {
    teamId: "team-destination",
    teamName: "Destination",
    use: true,
    manageAccounts: true,
    personal: false,
  },
];

function request(body: unknown = { destinationTeamId: "team-destination" }): Request {
  return new Request(
    `https://coderouter.dev/api/coderouter/accounts/${ACCOUNT_ID}/transfer`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  );
}

describe("coderouter account transfer route", () => {
  test("transfers an account only after validating both team permissions", async () => {
    const transfer = mock(async () => true);
    const POST = makeCoderouterTransferHandler({
      resolve: mock(async () => context) as never,
      listTeams: mock(async () => teams),
      transfer,
    });

    const response = await POST(request(), { params: Promise.resolve({ accountId: ACCOUNT_ID }) });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      accountId: ACCOUNT_ID,
      sourceTeamId: "team-source",
      destinationTeamId: "team-destination",
    });
    expect(transfer).toHaveBeenCalledWith({
      accountId: ACCOUNT_ID,
      sourceTeamId: "team-source",
      destinationTeamId: "team-destination",
      stackUserId: "user-1",
    });
  });

  test("rejects a destination without account-management permission", async () => {
    const transfer = mock(async () => true);
    const POST = makeCoderouterTransferHandler({
      resolve: mock(async () => context) as never,
      listTeams: mock(async () => teams.map((team) =>
        team.teamId === "team-destination" ? { ...team, manageAccounts: false } : team,
      )),
      transfer,
    });

    const response = await POST(request(), { params: Promise.resolve({ accountId: ACCOUNT_ID }) });

    expect(response.status).toBe(403);
    expect(transfer).not.toHaveBeenCalled();
  });

  test("rejects a source without account-management permission", async () => {
    const transfer = mock(async () => true);
    const POST = makeCoderouterTransferHandler({
      resolve: mock(async () => ({
        ...context,
        value: { ...context.value, team: { ...context.value.team, manageAccounts: false } },
      })) as never,
      listTeams: mock(async () => teams),
      transfer,
    });

    const response = await POST(request(), { params: Promise.resolve({ accountId: ACCOUNT_ID }) });

    expect(response.status).toBe(403);
    expect(transfer).not.toHaveBeenCalled();
  });

  test("rejects malformed account IDs before reading or transferring", async () => {
    const transfer = mock(async () => true);
    const listTeams = mock(async () => teams);
    const POST = makeCoderouterTransferHandler({
      resolve: mock(async () => context) as never,
      listTeams,
      transfer,
    });
    const response = await POST(new Request(
      "https://coderouter.dev/api/coderouter/accounts/not-an-id/transfer",
      { method: "POST" },
    ), { params: Promise.resolve({ accountId: "not-an-id" }) });

    expect(response.status).toBe(400);
    expect(listTeams).not.toHaveBeenCalled();
    expect(transfer).not.toHaveBeenCalled();
  });
});

function authedUser(teamIds: readonly string[]): AuthedUser {
  return {
    id: "user-1",
    displayName: "User",
    primaryEmail: "user@example.com",
    billingCustomerType: "team",
    billingTeamId: "team-source",
    selectedTeamId: "team-source",
    teams: teamIds.map((id) => ({ id, displayName: id, billingPlanId: null, billingSeats: null })),
    teamIds,
    userBillingPlanId: null,
    billingPlanId: null,
    billingSeats: null,
  };
}

describe("coderouter transfer destination membership", () => {
  // The source request's identity carries only its selected and requested
  // team, so a destination the caller belongs to is missing from user.teams.
  test("re-verifies the destination with an exact team lookup", async () => {
    const verify = mock(async (_request: Request, _signal: AbortSignal, options?: { requestedTeamId?: string | null }) =>
      authedUser(options?.requestedTeamId === "team-destination"
        ? ["team-source", "team-destination"]
        : ["team-source"]));

    const teams = await transferDestinationTeams(authedUser(["team-source"]), request(), "team-destination", verify as never);

    expect(teams.some((team) => team.teamId === "team-destination" && team.manageAccounts)).toBe(true);
    expect(verify).toHaveBeenCalledTimes(1);
    expect(verify.mock.calls[0]?.[2]).toEqual({ requestedTeamId: "team-destination", allowCookie: true });
  });

  test("offers no destination when the re-verified identity is a different user", async () => {
    const verify = mock(async () => ({ ...authedUser(["team-source", "team-destination"]), id: "someone-else" }));

    const teams = await transferDestinationTeams(authedUser(["team-source"]), request(), "team-destination", verify as never);

    expect(teams.some((team) => team.teamId === "team-destination")).toBe(false);
  });

  test("offers no destination the caller does not belong to", async () => {
    const verify = mock(async () => authedUser(["team-source"]));

    const teams = await transferDestinationTeams(authedUser(["team-source"]), request(), "team-destination", verify as never);

    expect(teams.some((team) => team.teamId === "team-destination")).toBe(false);
  });
});
