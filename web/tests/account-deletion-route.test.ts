import { beforeEach, describe, expect, mock, test } from "bun:test";

const deleteUser = mock(async () => {});
const getUser = mock(async () => ({ id: "user-1", delete: deleteUser }));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const route = await import("../app/api/account/deletion/route");

beforeEach(() => {
  deleteUser.mockClear();
  getUser.mockClear();
  getUser.mockResolvedValue({ id: "user-1", delete: deleteUser });
});

describe("account deletion route", () => {
  test("rejects requests without native Stack tokens", async () => {
    const response = await route.DELETE(
      new Request("https://cmux.test/api/account/deletion", { method: "DELETE" }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(getUser).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
  });

  test("deletes the Stack user for the native token pair", async () => {
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
    expect(deleteUser).toHaveBeenCalledTimes(1);
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
    expect(deleteUser).not.toHaveBeenCalled();
  });
});
