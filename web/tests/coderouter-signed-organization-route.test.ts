import { expect, test } from "bun:test";
import { organizationsGet } from "../app/api/subrouter/teams/route";

test("signed VM organization requests use the token team without Stack team selection", async () => {
  const request = new Request("https://coderouter.test/api/coderouter/organizations", {
    headers: { "x-cmux-authorization": "Bearer signed-vm-token" },
  });
  const response = await organizationsGet(
    request,
    async () => {
      throw new Error("Stack team resolution must not run for a signed VM");
    },
    async () => ({
      ok: true as const,
      identity: {
        teamId: "team-vm",
        stackUserId: "user-vm",
        vmId: "00000000-0000-4000-8000-000000000001",
        token: "signed-vm-token",
      },
    }),
  );

  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toEqual({
    selectedTeamId: "team-vm",
    fixed: true,
    teams: [{
      id: "team-vm",
      name: "team-vm",
      personal: false,
      permissions: { use: true, manageAccounts: false },
    }],
  });
});
