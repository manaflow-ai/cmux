import { beforeEach, describe, expect, mock, test } from "bun:test";

const calls: string[] = [];
let cleanupError: Error | null = null;
let postHogPreflightError: Error | null = null;
const assertPostHogDeletionConfigured = mock(() => {
  calls.push("posthog-preflight");
  if (postHogPreflightError) throw postHogPreflightError;
});
const deletePostHogPersonData = mock(async () => {
  calls.push("posthog-delete");
});
const markStackUserDeletionInProgress = mock(async () => {
  calls.push("mark-deleting");
});
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
    clientReadOnlyMetadata: {},
    listTeams: async () => [{ id: "team-1" }, { id: "team-selected" }],
    update: async () => undefined,
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
  isStackAccountDeletionInProgress: () => false,
  markStackUserDeletionInProgress,
}));

mock.module("../services/analytics/posthogDeletion", () => ({
  assertPostHogDeletionConfigured,
  deletePostHogPersonData,
}));

const route = await import("../app/api/account/deletion/route");

beforeEach(() => {
  calls.length = 0;
  cleanupError = null;
  postHogPreflightError = null;
  assertPostHogDeletionConfigured.mockClear();
  deletePostHogPersonData.mockClear();
  markStackUserDeletionInProgress.mockClear();
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
    expect(assertPostHogDeletionConfigured).not.toHaveBeenCalled();
    expect(markStackUserDeletionInProgress).not.toHaveBeenCalled();
    expect(deleteCmuxAccountData).not.toHaveBeenCalled();
    expect(deletePostHogPersonData).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
  });

  test("marks deletion in progress before cmux and PostHog cleanup", async () => {
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
    expect(deleteCmuxAccountData).toHaveBeenCalledTimes(1);
    expect(deleteUser).toHaveBeenCalledTimes(1);
    expect(deletePostHogPersonData).toHaveBeenCalledWith("user-1");
    expect(calls).toEqual(["posthog-preflight", "mark-deleting", "cleanup", "posthog-delete", "delete"]);
  });

  test("does not delete the Stack user when PostHog deletion is not configured", async () => {
    postHogPreflightError = new Error("PostHog account deletion is not configured");

    await expect(route.DELETE(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-1",
          "x-stack-refresh-token": "refresh-1",
        },
      }),
    )).rejects.toThrow("PostHog account deletion is not configured");

    expect(calls).toEqual(["posthog-preflight"]);
    expect(markStackUserDeletionInProgress).not.toHaveBeenCalled();
    expect(deleteCmuxAccountData).not.toHaveBeenCalled();
    expect(deletePostHogPersonData).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
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

    expect(calls).toEqual(["posthog-preflight", "mark-deleting", "cleanup"]);
    expect(deletePostHogPersonData).not.toHaveBeenCalled();
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
    expect(assertPostHogDeletionConfigured).not.toHaveBeenCalled();
    expect(markStackUserDeletionInProgress).not.toHaveBeenCalled();
    expect(deleteCmuxAccountData).not.toHaveBeenCalled();
    expect(deletePostHogPersonData).not.toHaveBeenCalled();
    expect(deleteUser).not.toHaveBeenCalled();
  });
});
