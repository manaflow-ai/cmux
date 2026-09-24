import { describe, expect, mock, test } from "bun:test";

import { makeCoderouterTransferHandler } from "../app/api/coderouter/accounts/[accountId]/transfer/route";

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
    expect(response.headers.get("cache-control")).toBe("no-store");
    // The refusal names the destination team, whose permission is missing.
    expect(await response.json()).toMatchObject({
      error: "destination_forbidden",
      code: "team_permission_required",
      teamId: "team-destination",
      teamName: "Destination",
      permission: "$manage_api_keys",
      action: "transfer_account",
      retryable: false,
    });
    expect(transfer).not.toHaveBeenCalled();
  });

  test("a destination the caller cannot see stays a plain refusal", async () => {
    const transfer = mock(async () => true);
    const POST = makeCoderouterTransferHandler({
      resolve: mock(async () => context) as never,
      listTeams: mock(async () => teams),
      transfer,
    });

    const response = await POST(request({ destinationTeamId: "team-unknown" }), { params: Promise.resolve({ accountId: ACCOUNT_ID }) });

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "destination_forbidden" });
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
    const body = await response.json();
    expect(body).toMatchObject({
      error: "forbidden",
      code: "team_permission_required",
      teamId: "team-source",
      teamName: "Source",
      permission: "$manage_api_keys",
      action: "transfer_account",
    });
    expect(body.options.map((option: { kind: string }) => option.kind)).toEqual(["switch_team", "ask_admin"]);
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
