import { describe, expect, test } from "bun:test";
import {
  claimCliAuthTokens,
  type CliAuthRepository,
  type CliAuthTokenMinter,
  type CliAuthTokens,
} from "../services/vault/cliAuth";

type FakeRow = {
  id: string;
  deviceCodeHash: string;
  status: string;
  userId: string | null;
  expiresAt: Date;
};

function fakeRepository(row: FakeRow): CliAuthRepository {
  return {
    transaction: async (run) =>
      await run({
        selectApprovedForClaim: async (deviceCodeHash, now) => {
          if (
            row.deviceCodeHash === deviceCodeHash &&
            row.status === "approved" &&
            row.expiresAt.getTime() > now.getTime()
          ) {
            return { id: row.id, userId: row.userId };
          }
          return null;
        },
        markClaimed: async (id) => {
          if (row.id === id) {
            row.status = "claimed";
          }
        },
        selectStatus: async (deviceCodeHash) => {
          if (row.deviceCodeHash !== deviceCodeHash) return null;
          return { status: row.status, expiresAt: row.expiresAt };
        },
      }),
    restoreApproved: async (id) => {
      if (row.id === id && row.status === "claimed") {
        row.status = "approved";
      }
    },
  };
}

function countingMinter(
  tokens: CliAuthTokens | null,
): { minter: CliAuthTokenMinter; calls: string[] } {
  const calls: string[] = [];
  return {
    minter: async (userId) => {
      calls.push(userId);
      return tokens;
    },
    calls,
  };
}

const NOW = new Date("2026-07-04T12:00:00Z");
const LATER = new Date("2026-07-04T12:05:00Z");

function approvedRow(): FakeRow {
  return {
    id: "request-1",
    deviceCodeHash: "hash-1",
    status: "approved",
    userId: "user-1",
    expiresAt: LATER,
  };
}

describe("vault CLI auth claim", () => {
  test("mints tokens exactly once for the approving user", async () => {
    const row = approvedRow();
    const { minter, calls } = countingMinter({ accessToken: "access-1", refreshToken: "refresh-1" });

    await expect(claimCliAuthTokens(fakeRepository(row), minter, "hash-1", NOW)).resolves.toEqual({
      status: "approved",
      accessToken: "access-1",
      refreshToken: "refresh-1",
    });
    expect(calls).toEqual(["user-1"]);
    expect(row.status).toBe("claimed");
  });

  test("second claim is terminal and does not mint again", async () => {
    const row = approvedRow();
    const repository = fakeRepository(row);
    const { minter, calls } = countingMinter({ accessToken: "access-1", refreshToken: "refresh-1" });

    await claimCliAuthTokens(repository, minter, "hash-1", NOW);
    await expect(claimCliAuthTokens(repository, minter, "hash-1", NOW)).resolves.toEqual({
      status: "expired",
    });
    expect(calls).toEqual(["user-1"]);
  });

  test("pending row stays pending and never mints", async () => {
    const row = approvedRow();
    row.status = "pending";
    row.userId = null;
    const { minter, calls } = countingMinter({ accessToken: "a", refreshToken: "r" });

    await expect(claimCliAuthTokens(fakeRepository(row), minter, "hash-1", NOW)).resolves.toEqual({
      status: "pending",
    });
    expect(calls).toEqual([]);
    expect(row.status).toBe("pending");
  });

  test("expired approval never mints", async () => {
    const row = approvedRow();
    row.expiresAt = new Date(NOW.getTime() - 1000);
    const { minter, calls } = countingMinter({ accessToken: "a", refreshToken: "r" });

    await expect(claimCliAuthTokens(fakeRepository(row), minter, "hash-1", NOW)).resolves.toEqual({
      status: "expired",
    });
    expect(calls).toEqual([]);
  });

  test("mint failure restores the approval so the next poll can retry", async () => {
    const row = approvedRow();
    const repository = fakeRepository(row);
    const failing = countingMinter(null);

    await expect(claimCliAuthTokens(repository, failing.minter, "hash-1", NOW)).resolves.toEqual({
      status: "pending",
    });
    expect(row.status).toBe("approved");

    const succeeding = countingMinter({ accessToken: "access-2", refreshToken: "refresh-2" });
    await expect(claimCliAuthTokens(repository, succeeding.minter, "hash-1", NOW)).resolves.toEqual({
      status: "approved",
      accessToken: "access-2",
      refreshToken: "refresh-2",
    });
    expect(row.status).toBe("claimed");
  });

  test("mint throw is handled like a mint failure", async () => {
    const row = approvedRow();
    const repository = fakeRepository(row);
    const throwing: CliAuthTokenMinter = async () => {
      throw new Error("stack unavailable");
    };

    await expect(claimCliAuthTokens(repository, throwing, "hash-1", NOW)).resolves.toEqual({
      status: "pending",
    });
    expect(row.status).toBe("approved");
  });

  test("unknown device code is terminal", async () => {
    const row = approvedRow();
    const { minter, calls } = countingMinter({ accessToken: "a", refreshToken: "r" });

    await expect(claimCliAuthTokens(fakeRepository(row), minter, "hash-other", NOW)).resolves.toEqual({
      status: "expired",
    });
    expect(calls).toEqual([]);
  });
});
