import { describe, expect, mock, test } from "bun:test";
import { accountDeletionUserHash } from "../services/account/deletionLock";
import { withVaultUserQuotaLock } from "../services/vault/usage";

describe("vault usage quota locking", () => {
  test("runs quota projection and grant reservation inside a per-user advisory transaction", async () => {
    const tx = fakeVaultLockTransaction([]);
    const db = {
      transaction: mock(async (...args: unknown[]) => {
        const run = args[0] as (tx: unknown) => Promise<string>;
        return await run(tx);
      }),
    };
    const run = mock(async (lockedDb: unknown) => {
      expect(lockedDb).toBe(tx);
      return "reserved";
    });

    const result = await withVaultUserQuotaLock(
      db as never,
      "user-quota-lock",
      run as never,
    );

    expect(result).toBe("reserved");
    expect(db.transaction).toHaveBeenCalledTimes(1);
    expect(tx.execute).toHaveBeenCalledTimes(3);
    expect(run).toHaveBeenCalledTimes(1);
  });

  test("blocks vault writes after account deletion starts", async () => {
    const tx = fakeVaultLockTransaction([{
      userIdHash: accountDeletionUserHash("deleting-user"),
      status: "in_progress",
    }]);
    const db = {
      transaction: mock(async (...args: unknown[]) => {
        const run = args[0] as (tx: unknown) => Promise<void>;
        return await run(tx);
      }),
    };
    const run = mock(async () => undefined);

    await expect(withVaultUserQuotaLock(
      db as never,
      "deleting-user",
      run as never,
    )).rejects.toThrow("Vault writes are disabled while account deletion is in progress.");

    expect(tx.execute).toHaveBeenCalledTimes(3);
    expect(run).not.toHaveBeenCalled();
  });

  test("allows the account deletion worker to drain vault rows under the same lock", async () => {
    const tx = fakeVaultLockTransaction([{
      userIdHash: accountDeletionUserHash("deleting-user"),
      status: "in_progress",
    }]);
    const db = {
      transaction: mock(async (...args: unknown[]) => {
        const run = args[0] as (tx: unknown) => Promise<string>;
        return await run(tx);
      }),
    };
    const run = mock(async () => "drained");

    const result = await withVaultUserQuotaLock(
      db as never,
      "deleting-user",
      run as never,
      { allowAccountDeletion: true },
    );

    expect(result).toBe("drained");
    expect(tx.execute).toHaveBeenCalledTimes(2);
    expect(run).toHaveBeenCalledTimes(1);
  });
});

function fakeVaultLockTransaction(rows: unknown[]) {
  return {
    execute: mock(async () => undefined),
    select: mock(() => selectBuilder(rows)),
  };
}

function selectBuilder(rows: unknown[]) {
  const builder = {
    from: () => builder,
    where: () => builder,
    limit: async () => rows,
  };
  return builder;
}
