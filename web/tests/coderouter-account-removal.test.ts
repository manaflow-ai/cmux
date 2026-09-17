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
    });
    const response = await handler(
      new Request("https://coderouter.dev/api/coderouter/accounts/" + accountId, {
        method: "DELETE",
      }),
      { params: Promise.resolve({ accountId }) },
    );
    expect(response.status).toBe(200);
    expect(removed).toEqual({ teamId: "team-1", accountId });
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
    });
    const response = await handler(
      new Request("https://coderouter.dev", { method: "DELETE" }),
      { params: Promise.resolve({ accountId: "../other-team" }) },
    );
    expect(response.status).toBe(400);
    expect(called).toBe(false);
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
