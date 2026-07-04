import { and, eq, gt } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { vaultCliAuthRequests } from "../../db/schema";

export type CliAuthTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

type ApprovedClaimRow = {
  readonly id: string;
  readonly tokens: CliAuthTokens | null;
};

type StatusRow = {
  readonly status: string;
  readonly expiresAt: Date;
};

export type CliAuthTransaction = {
  readonly selectApprovedForClaim: (
    deviceCodeHash: string,
    now: Date,
  ) => Promise<ApprovedClaimRow | null>;
  readonly markClaimed: (id: string) => Promise<void>;
  readonly selectStatus: (deviceCodeHash: string) => Promise<StatusRow | null>;
};

export type CliAuthRepository = {
  readonly transaction: <T>(run: (tx: CliAuthTransaction) => Promise<T>) => Promise<T>;
};

export type ClaimCliAuthResult =
  | { readonly status: "approved"; readonly accessToken: string; readonly refreshToken: string }
  | { readonly status: "pending" | "expired" };

export async function claimCliAuthTokens(
  repository: CliAuthRepository,
  deviceCodeHash: string,
  now: Date,
): Promise<ClaimCliAuthResult> {
  return await repository.transaction(async (tx) => {
    const approved = await tx.selectApprovedForClaim(deviceCodeHash, now);
    if (approved?.tokens) {
      await tx.markClaimed(approved.id);
      return {
        status: "approved",
        accessToken: approved.tokens.accessToken,
        refreshToken: approved.tokens.refreshToken,
      };
    }

    const row = await tx.selectStatus(deviceCodeHash);
    if (!row) return { status: "expired" };
    if (row.expiresAt.getTime() <= now.getTime()) return { status: "expired" };
    if (row.status === "pending") return { status: "pending" };
    return { status: "expired" };
  });
}

export function drizzleCliAuthRepository(): CliAuthRepository {
  const db = cloudDb();
  return {
    transaction: async (run) =>
      await db.transaction(async (tx) =>
        await run({
          selectApprovedForClaim: async (deviceCodeHash, now) => {
            const [row] = await tx
              .select({
                id: vaultCliAuthRequests.id,
                tokens: vaultCliAuthRequests.tokens,
              })
              .from(vaultCliAuthRequests)
              .where(
                and(
                  eq(vaultCliAuthRequests.deviceCodeHash, deviceCodeHash),
                  eq(vaultCliAuthRequests.status, "approved"),
                  gt(vaultCliAuthRequests.expiresAt, now),
                ),
              )
              .limit(1)
              .for("update");
            return row ?? null;
          },
          markClaimed: async (id) => {
            await tx
              .update(vaultCliAuthRequests)
              .set({ status: "claimed", tokens: null })
              .where(eq(vaultCliAuthRequests.id, id));
          },
          selectStatus: async (deviceCodeHash) => {
            const [row] = await tx
              .select({
                status: vaultCliAuthRequests.status,
                expiresAt: vaultCliAuthRequests.expiresAt,
              })
              .from(vaultCliAuthRequests)
              .where(eq(vaultCliAuthRequests.deviceCodeHash, deviceCodeHash))
              .limit(1);
            return row ?? null;
          },
        }),
      ),
  };
}
