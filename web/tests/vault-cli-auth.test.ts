import { describe, expect, test } from "bun:test";
import {
  claimCliAuthTokens,
  type CliAuthRepository,
  type CliAuthTokens,
} from "../services/vault/cliAuth";

type FakeRow = {
  id: string;
  deviceCodeHash: string;
  status: string;
  tokens: CliAuthTokens | null;
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
            return { id: row.id, tokens: row.tokens };
          }
          return null;
        },
        markClaimed: async (id) => {
          if (row.id === id) {
            row.status = "claimed";
            row.tokens = null;
          }
        },
        selectStatus: async (deviceCodeHash) => {
          if (row.deviceCodeHash !== deviceCodeHash) return null;
          return { status: row.status, expiresAt: row.expiresAt };
        },
      }),
  };
}

describe("vault CLI auth claim", () => {
  test("returns approved tokens exactly once and clears stored tokens", async () => {
    const now = new Date("2026-07-04T12:00:00Z");
    const row: FakeRow = {
      id: "request-1",
      deviceCodeHash: "hash-1",
      status: "approved",
      tokens: { accessToken: "access-1", refreshToken: "refresh-1" },
      expiresAt: new Date("2026-07-04T12:05:00Z"),
    };

    await expect(claimCliAuthTokens(fakeRepository(row), "hash-1", now)).resolves.toEqual({
      status: "approved",
      accessToken: "access-1",
      refreshToken: "refresh-1",
    });
    expect(row.status).toBe("claimed");
    expect(row.tokens).toBeNull();

    await expect(claimCliAuthTokens(fakeRepository(row), "hash-1", now)).resolves.toEqual({
      status: "expired",
    });
  });

  test("reports pending without mutating the request", async () => {
    const now = new Date("2026-07-04T12:00:00Z");
    const row: FakeRow = {
      id: "request-2",
      deviceCodeHash: "hash-2",
      status: "pending",
      tokens: null,
      expiresAt: new Date("2026-07-04T12:05:00Z"),
    };

    await expect(claimCliAuthTokens(fakeRepository(row), "hash-2", now)).resolves.toEqual({
      status: "pending",
    });
    expect(row.status).toBe("pending");
  });
});
