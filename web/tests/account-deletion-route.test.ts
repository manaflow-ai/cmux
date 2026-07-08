import { beforeEach, describe, expect, mock, test } from "bun:test";

const accountDeletionModule = await import("../services/account/deletion");
const realIsStackAccountDeletionInProgress = accountDeletionModule.isStackAccountDeletionInProgress;
const realMarkStackUserDeletionInProgress = accountDeletionModule.markStackUserDeletionInProgress;
const calls: string[] = [];
const scheduledCallbacks: Array<() => Promise<void>> = [];
let stackUserMetadata: unknown = {};
let postHogPreflightError: Error | null = null;
let enqueueStatus: "pending" | "in_progress" | "completed" | "failed" = "pending";
let enqueueError: Error | null = null;
const assertPostHogDeletionConfigured = mock(() => {
  calls.push("posthog-preflight");
  if (postHogPreflightError) throw postHogPreflightError;
});
type NativeTokenStore = { accessToken: string; refreshToken: string };
const markStackUserDeletionInProgress = mock(async (user) => {
  calls.push("mark-deleting");
  await realMarkStackUserDeletionInProgress(
    user as Parameters<typeof realMarkStackUserDeletionInProgress>[0],
  );
});
const enqueueAccountDeletion = mock(async (_input?: unknown) => {
  calls.push("enqueue");
  if (enqueueError) throw enqueueError;
  return { userIdHash: "hash-user-1", status: enqueueStatus };
});
const processAccountDeletionForUser = mock(async (_input?: unknown) => {
  const input = _input as { userId: string };
  calls.push(`process:${input.userId}`);
  return "processed" as const;
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
    enqueueAccountDeletion: async (input) =>
      await enqueueAccountDeletion(input) as Awaited<ReturnType<typeof accountDeletionModule.enqueueAccountDeletion>>,
    processAccountDeletionForUser: async (input) =>
      await processAccountDeletionForUser(input) as "processed" | "skipped",
    scheduleAfterResponse: (callback) => {
      calls.push("schedule");
      scheduledCallbacks.push(callback);
    },
  });
}

beforeEach(() => {
  calls.length = 0;
  scheduledCallbacks.length = 0;
  stackUserMetadata = {};
  postHogPreflightError = null;
  enqueueStatus = "pending";
  enqueueError = null;
  assertPostHogDeletionConfigured.mockClear();
  markStackUserDeletionInProgress.mockClear();
  enqueueAccountDeletion.mockClear();
  processAccountDeletionForUser.mockClear();
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
    expect(enqueueAccountDeletion).not.toHaveBeenCalled();
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
    expect(scheduledCallbacks).toHaveLength(0);
    expect(deleteUser).not.toHaveBeenCalled();
  });

  test("marks deletion in progress, enqueues cleanup, and returns before background deletion", async () => {
    const response = await deleteAccount(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-1",
          "x-stack-refresh-token": "refresh-1",
        },
      }),
    );

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ ok: true, status: "pending" });
    expect(getUser).toHaveBeenCalledWith({
      tokenStore: { accessToken: "access-1", refreshToken: "refresh-1" },
    });
    expect(enqueueAccountDeletion).toHaveBeenCalledWith({
      userId: "user-1",
    });
    expect(realIsStackAccountDeletionInProgress(stackUserMetadata)).toBe(true);
    expect(deleteUser).not.toHaveBeenCalled();
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
    expect(calls).toEqual(["posthog-preflight", "enqueue", "mark-deleting", "schedule"]);
    expect(scheduledCallbacks).toHaveLength(1);

    await scheduledCallbacks[0]();

    expect(processAccountDeletionForUser).toHaveBeenCalledWith({ userId: "user-1" });
    expect(calls).toEqual([
      "posthog-preflight",
      "enqueue",
      "mark-deleting",
      "schedule",
      "process:user-1",
    ]);
  });

  test("returns completed deletion without scheduling duplicate cleanup", async () => {
    enqueueStatus = "completed";

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
    expect(await response.json()).toEqual({ ok: true, status: "completed" });
    expect(enqueueAccountDeletion).toHaveBeenCalledWith({ userId: "user-1" });
    expect(markStackUserDeletionInProgress).not.toHaveBeenCalled();
    expect(scheduledCallbacks).toHaveLength(0);
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
  });

  test("does not mark Stack deletion metadata when enqueue fails", async () => {
    enqueueError = new Error("database unavailable");

    await expect(deleteAccount(
      new Request("https://cmux.test/api/account/deletion", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-1",
          "x-stack-refresh-token": "refresh-1",
        },
      }),
    )).rejects.toThrow("database unavailable");

    expect(calls).toEqual(["posthog-preflight", "enqueue"]);
    expect(markStackUserDeletionInProgress).not.toHaveBeenCalled();
    expect(realIsStackAccountDeletionInProgress(stackUserMetadata)).toBe(false);
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
    expect(scheduledCallbacks).toHaveLength(0);
    expect(deleteUser).not.toHaveBeenCalled();
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
    expect(enqueueAccountDeletion).not.toHaveBeenCalled();
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
    expect(scheduledCallbacks).toHaveLength(0);
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
    expect(enqueueAccountDeletion).not.toHaveBeenCalled();
    expect(processAccountDeletionForUser).not.toHaveBeenCalled();
    expect(scheduledCallbacks).toHaveLength(0);
    expect(deleteUser).not.toHaveBeenCalled();
  });
});
