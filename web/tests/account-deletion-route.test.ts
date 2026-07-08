import { beforeEach, describe, expect, mock, test } from "bun:test";

const accountDeletionModule = await import("../services/account/deletion");
const realIsStackAccountDeletionInProgress = accountDeletionModule.isStackAccountDeletionInProgress;
const realMarkStackUserDeletionInProgress = accountDeletionModule.markStackUserDeletionInProgress;
const calls: string[] = [];
let stackUserMetadata: unknown = {};
let cleanupError: Error | null = null;
let postHogPreflightError: Error | null = null;
const assertPostHogDeletionConfigured = mock(() => {
  calls.push("posthog-preflight");
  if (postHogPreflightError) throw postHogPreflightError;
});
const deletePostHogPersonData = mock(async () => {
  calls.push("posthog-delete");
});
type NativeTokenStore = { accessToken: string; refreshToken: string };
const markStackUserDeletionInProgress = mock(async (user) => {
  calls.push("mark-deleting");
  await realMarkStackUserDeletionInProgress(
    user as Parameters<typeof realMarkStackUserDeletionInProgress>[0],
  );
});
const deleteCmuxAccountData = mock(async () => {
  calls.push("cleanup");
  if (cleanupError) throw cleanupError;
});
const deleteUser = mock(async () => {});
const getUser = mock(async (_options?: unknown) => stackUser());

const route = await import("../app/api/account/deletion/route");

function stackUser() {
  return {
    id: "user-1",
    get clientReadOnlyMetadata() {
      return stackUserMetadata;
    },
    update: async ({ clientReadOnlyMetadata }: { clientReadOnlyMetadata: Record<string, unknown> }) => {
      stackUserMetadata = clientReadOnlyMetadata;
    },
    delete: async () => {
      calls.push("delete");
      await deleteUser();
    },
  };
}

function deleteAccount(request: Request): Promise<Response> {
  return route.deleteAccountWithDependencies(request, {
    isStackConfigured: () => true,
    getUser: async (tokenStore) =>
      (await getUser({ tokenStore })) as ReturnType<typeof stackUser> | null,
    assertPostHogDeletionConfigured,
    markStackUserDeletionInProgress,
    deleteCmuxAccountData,
    deletePostHogPersonData,
  });
}

beforeEach(() => {
  calls.length = 0;
  stackUserMetadata = {};
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
    const response = await deleteAccount(
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
    const response = await deleteAccount(
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
    });
    expect(deleteCmuxAccountData).toHaveBeenCalledTimes(1);
    expect(realIsStackAccountDeletionInProgress(stackUserMetadata)).toBe(true);
    expect(deleteUser).toHaveBeenCalledTimes(1);
    expect(deletePostHogPersonData).toHaveBeenCalledWith("user-1");
    expect(calls).toEqual(["posthog-preflight", "mark-deleting", "cleanup", "posthog-delete", "delete"]);
  });

  test("does not delete the Stack user when PostHog deletion is not configured", async () => {
    postHogPreflightError = new Error("PostHog account deletion is not configured");

    await expect(deleteAccount(
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

    await expect(deleteAccount(
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

    const response = await deleteAccount(
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
