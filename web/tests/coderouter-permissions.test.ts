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
const { canManageCoderouterAccounts } = await import("../services/coderouter/permissions");
beforeEach(() => { grant = false; available = true; hasPermission.mockClear(); });

describe("CodeRouter account management", () => {
  test("personal scope belongs to the signed-in user", async () => {
    expect(await canManageCoderouterAccounts("user-1", "user-1")).toBe(true);
    expect(hasPermission).not.toHaveBeenCalled();
  });
  test("team membership alone does not confer account administration", async () => {
    expect(await canManageCoderouterAccounts("user-1", "team-1")).toBe(false);
    grant = true;
    expect(await canManageCoderouterAccounts("user-1", "team-1")).toBe(true);
  });
  test("permission lookup failure cannot become an allow", async () => {
    available = false;
    await expect(canManageCoderouterAccounts("user-1", "team-1")).rejects.toThrow("authorization unavailable");
  });
});
