import { describe, expect, mock, test } from "bun:test";
import { withVaultUserQuotaLock } from "../services/vault/usage";

describe("vault usage quota locking", () => {
  test("runs quota projection and grant reservation inside a per-user advisory transaction", async () => {
    const tx = {
      execute: mock(async () => undefined),
    };
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
    expect(tx.execute).toHaveBeenCalledTimes(1);
    expect(run).toHaveBeenCalledTimes(1);
  });
});
