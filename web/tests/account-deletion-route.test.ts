import { beforeEach, describe, expect, mock, test } from "bun:test";

const calls: string[] = [];
let cleanupError: Error | null = null;
const deleteCmuxAccountData = mock(async () => {
  calls.push("cleanup");
  if (cleanupError) throw cleanupError;
});
const deleteUser = mock(async () => {});
const getUser = mock(async () => stackUser());

function stackUser() {
  return {
    id: "user-1",
    selectedTeam: { id: "team-selected" },
    listTeams: async () => [{ id: "team-1" }, { id: "team-selected" }],
    delete: async () => {
      calls.push("delete");
      await deleteUser();
    },
  };
}

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../services/account/deletion", () => ({
  deleteCmuxAccountData,
}));

const route = await import("../app/api/account/deletion/route");

beforeEach(() => {
  calls.length = 0;
  cleanupError = null;
  deleteCmuxAccountData.mockClear();
  deleteUser.mockClear();
  getUser.mockClear();
  getUser.mockResolvedValue(stackUser());
});

describe("account deletion route", () => {
  test("rejects requests without native Stack tokens", async () => {
    const response = await route.DELETE(
      new Request("https://cmux.test/api/account/deletion", { method: "DELETE" }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(getUser).not.toHaveBeenCalled();
    expect(deleteCmuxAccountData).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
  });

  test("deletes cmux-owned data before deleting the Stack user for the native token pair", async () => {
    const response = await route.DELETE(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-1",
          "x-stack-refresh-token": "refresh-1",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(getUser).toHaveBeenCalledWith({
      tokenStore: { accessToken: "access-1", refreshToken: "refresh-1" },
    });
    expect(deleteCmuxAccountData).toHaveBeenCalledWith({
      userId: "user-1",
      teamIds: ["team-selected", "team-1"],
    });
    expect(deleteUser).toHaveBeenCalledTimes(1);
    expect(calls).toEqual(["cleanup", "delete"]);
  });

  test("does not delete the Stack user when cmux-owned cleanup fails", async () => {
    cleanupError = new Error("cleanup failed");

    await expect(route.DELETE(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-1",
          "x-stack-refresh-token": "refresh-1",
        },
      }),
    )).rejects.toThrow("cleanup failed");

    expect(calls).toEqual(["cleanup"]);
    expect(deleteUser).not.toHaveBeenCalled();
  });

  test("rejects stale native tokens without deleting anything", async () => {
    getUser.mockResolvedValue(null);

    const response = await route.DELETE(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer stale-access",
          "x-stack-refresh-token": "stale-refresh",
        },
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(deleteCmuxAccountData).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
  });
});
