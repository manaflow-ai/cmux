import { describe, expect, test } from "bun:test";
import { createDeleteAccountHandler } from "../app/api/coderouter/accounts/[accountId]/route";
import { createAccountRemover } from "../services/coderouter/accounts";

const accountId = "00000000-0000-4000-8000-000000000001";

describe("coderouter account removal", () => {
  test("scopes deletion to the resolved team", async () => {
    let removed: { teamId: string; accountId: string } | undefined;
    const handler = createDeleteAccountHandler({
      resolve: async () => {
        return {
          ok: true as const,
          value: {
            user: {} as never,
            access: { kind: "user" as const, userId: "test-user" },
            team: {
              teamId: "team-1",
              teamName: "Team",
              use: true,
              manageAccounts: true,
            },
          },
        };
      },
      remove: async (input) => {
        removed = input;
        return {
          removed: true,
          lastAccount: true,
          legacyCleanupPending: false,
        };
      },
      visible: async () => false,
    });
    const response = await handler(
      new Request("https://coderouter.dev/api/coderouter/accounts/" + accountId, {
        method: "DELETE",
      }),
      { params: Promise.resolve({ accountId }) },
    );
    expect(response.status).toBe(200);
    expect(removed).toEqual({ teamId: "team-1", accountId, access: { kind: "user", userId: "test-user" } });
    expect(await response.json()).toEqual({
      removed: true,
      lastAccount: true,
      legacyCleanupPending: false,
    });
  });

  test("rejects malformed IDs before touching storage", async () => {
    let called = false;
    const handler = createDeleteAccountHandler({
      resolve: async () => ({
        ok: true as const,
        value: {
          user: {} as never,
            access: { kind: "user" as const, userId: "test-user" },
          team: {
            teamId: "team-1",
            teamName: "Team",
            use: true,
            manageAccounts: true,
          },
        },
      }),
      remove: async () => {
        called = true;
        return {
          removed: true,
          lastAccount: false,
          legacyCleanupPending: false,
        };
      },
      visible: async () => false,
    });
    const response = await handler(
      new Request("https://coderouter.dev", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "../other-team" }) },
    );
    expect(response.status).toBe(400);
    expect(called).toBe(false);
  });
});

describe("coderouter account removal without account administration", () => {
  // A team member without the Stack `$manage_api_keys` team permission.
  const member = async () => ({
    ok: true as const,
    value: {
      user: { id: "user_2" } as never,
      access: { kind: "user" as const, userId: "user_2" },
      team: {
        teamId: "team-1",
        teamName: "Benjamin Swerdlow's Team",
        use: true,
        manageAccounts: false,
      },
    },
  });
  const request = () => new Request("https://coderouter.dev/api/coderouter/accounts/" + accountId, { method: "DELETE" });
  const params = { params: Promise.resolve({ accountId }) };
  type RemoveInput = { teamId: string; accountId: string; stackUserId?: string; access: unknown };

  function handler(options: { removed: boolean; visible: boolean }) {
    const calls: { remove: RemoveInput[]; visible: unknown[] } = { remove: [], visible: [] };
    const DELETE = createDeleteAccountHandler({
      resolve: member,
      remove: async (input) => {
        calls.remove.push(input);
        return { removed: options.removed, lastAccount: false, legacyCleanupPending: false };
      },
      visible: async (input: unknown) => {
        calls.visible.push(input);
        return options.visible;
      },
    } as Parameters<typeof createDeleteAccountHandler>[0]);
    return { DELETE, calls };
  }

  test("a member removes their own private account", async () => {
    const { DELETE, calls } = handler({ removed: true, visible: true });
    const response = await DELETE(request(), params);
    expect(response.status).toBe(200);
    // The delete itself is narrowed to the member's own private rows.
    expect(calls.remove).toEqual([
      { teamId: "team-1", accountId, stackUserId: "user_2", access: { kind: "own-private", userId: "user_2" } },
    ]);
    expect(calls.visible).toEqual([]);
  });

  test("a shared account explains which permission is missing", async () => {
    const { DELETE, calls } = handler({ removed: false, visible: true });
    const response = await DELETE(request(), params);
    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toMatchObject({
      error: "forbidden",
      code: "team_permission_required",
      teamId: "team-1",
      teamName: "Benjamin Swerdlow's Team",
      permission: "$manage_api_keys",
      action: "change_shared_account",
      options: [expect.objectContaining({ kind: "ask_admin" })],
      retryable: false,
    });
    expect(calls.visible).toEqual([{ teamId: "team-1", accountId, access: { kind: "user", userId: "user_2" } }]);
  });

  test("someone else's private account stays indistinguishable from a missing one", async () => {
    const { DELETE } = handler({ removed: false, visible: false });
    const response = await DELETE(request(), params);
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("not_found");
  });
});

describe("coderouter account-removal storage semantics", () => {
  test("deletes runtime ciphertext before the temporary rollback copy", async () => {
    const order: string[] = [];
    const remove = createAccountRemover({
      deleteRuntime: async () => {
        order.push("runtime");
        return { removed: true, lastAccount: false };
      },
      deleteLegacy: async () => {
        order.push("legacy");
      },
      withLease: async (_teamId, operation) => await operation(),
      report: () => {},
    });
    expect(await remove("team-1", accountId)).toEqual({
      removed: true,
      lastAccount: false,
      legacyCleanupPending: false,
    });
    expect(order).toEqual(["runtime", "legacy"]);
  });

  test("keeps runtime deletion successful when rollback-copy cleanup is unavailable", async () => {
    let reported = false;
    const remove = createAccountRemover({
      deleteRuntime: async () => ({ removed: true, lastAccount: true }),
      deleteLegacy: async () => {
        throw new Error("Stack unavailable");
      },
      withLease: async (_teamId, operation) => await operation(),
      report: (failure) => {
        reported = failure === "legacy_cleanup";
      },
    });
    expect(await remove("team-1", accountId)).toEqual({
      removed: true,
      lastAccount: true,
      legacyCleanupPending: true,
    });
    expect(reported).toBe(true);
  });
});
