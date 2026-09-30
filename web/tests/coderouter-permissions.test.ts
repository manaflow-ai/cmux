import { beforeEach, describe, expect, mock, test } from "bun:test";
let grant = false;
let available = true;
const hasPermission = mock(async (_team: unknown, permission: string) => {
  expect(permission).toBe("$manage_api_keys");
  return grant;
});
mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getUser: async () => { if (!available) throw new Error("offline"); return { hasPermission }; },
    getTeam: async (id: string) => ({ id }),
  }),
}));
const {
  apiKeyAdministrationRefusal,
  authorizedCoderouterTeams,
  canManageCoderouterApiKeys,
} = await import("../services/coderouter/permissions");
beforeEach(() => { grant = false; available = true; hasPermission.mockClear(); });

describe("CodeRouter account management", () => {
  test("every team member manages accounts without the Stack API-key permission", async () => {
    const teams = await authorizedCoderouterTeams({
      id: "user-1",
      teams: [{ id: "team-1", displayName: "Team One" }],
    } as never);
    const team = teams.find((candidate) => candidate.teamId === "team-1");
    expect(team).toMatchObject({ use: true, manageAccounts: true, manageApiKeys: false });
  });
});

describe("CodeRouter API key administration", () => {
  test("personal scope belongs to the signed-in user", async () => {
    expect(await canManageCoderouterApiKeys("user-1", "user-1")).toBe(true);
    expect(hasPermission).not.toHaveBeenCalled();
  });
  test("team membership alone does not confer API key administration", async () => {
    expect(await canManageCoderouterApiKeys("user-1", "team-1")).toBe(false);
    grant = true;
    expect(await canManageCoderouterApiKeys("user-1", "team-1")).toBe(true);
  });
  test("permission lookup failure cannot become an allow", async () => {
    available = false;
    await expect(canManageCoderouterApiKeys("user-1", "team-1")).rejects.toThrow("authorization unavailable");
  });
  test("the route gate answers 403 without the permission and 503 when Stack is unavailable", async () => {
    const refused = await apiKeyAdministrationRefusal("user-1", "team-1");
    expect(refused?.status).toBe(403);
    await expect(refused?.json()).resolves.toEqual({ error: "forbidden", permission: "$manage_api_keys" });
    grant = true;
    expect(await apiKeyAdministrationRefusal("user-1", "team-1")).toBeNull();
    available = false;
    const unavailable = await apiKeyAdministrationRefusal("user-1", "team-1");
    expect(unavailable?.status).toBe(503);
  });
});
