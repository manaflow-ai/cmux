import { and, eq, gt } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { vaultCliAuthRequests } from "../../db/schema";

export type CliAuthTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

type ApprovedClaimRow = {
  readonly id: string;
  readonly userId: string | null;
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
  readonly restoreApproved: (id: string) => Promise<void>;
};

/**
 * Mints a fresh Stack session for the approved user. Runs only after the claim
 * transaction has been won, so tokens are never persisted anywhere server-side.
 */
export type CliAuthTokenMinter = (userId: string) => Promise<CliAuthTokens | null>;

export type ClaimCliAuthResult =
  | { readonly status: "approved"; readonly accessToken: string; readonly refreshToken: string }
  | { readonly status: "pending" | "expired" };

export async function claimCliAuthTokens(
  repository: CliAuthRepository,
  mintTokens: CliAuthTokenMinter,
  deviceCodeHash: string,
  now: Date,
): Promise<ClaimCliAuthResult> {
  type ClaimOutcome =
    | { readonly kind: "claimed"; readonly id: string; readonly userId: string }
    | { readonly kind: "terminal"; readonly status: "pending" | "expired" };

  const claim = await repository.transaction<ClaimOutcome>(async (tx) => {
    const approved = await tx.selectApprovedForClaim(deviceCodeHash, now);
    if (approved?.userId) {
      await tx.markClaimed(approved.id);
      return { kind: "claimed", id: approved.id, userId: approved.userId };
    }

    const row = await tx.selectStatus(deviceCodeHash);
    if (!row) return { kind: "terminal", status: "expired" };
    if (row.expiresAt.getTime() <= now.getTime()) return { kind: "terminal", status: "expired" };
    if (row.status === "pending") return { kind: "terminal", status: "pending" };
    return { kind: "terminal", status: "expired" };
  });

  if (claim.kind === "terminal") return { status: claim.status };

  let tokens: CliAuthTokens | null = null;
  try {
    tokens = await mintTokens(claim.userId);
  } catch {
    tokens = null;
  }
  if (!tokens) {
    // Hand the request back so the CLI's next poll can retry instead of
    // burning the approval on a transient Stack failure. Expiry still bounds
    // the retry window.
    await repository.restoreApproved(claim.id);
    return { status: "pending" };
  }

  return {
    status: "approved",
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
  };
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
                userId: vaultCliAuthRequests.userId,
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
              .set({ status: "claimed" })
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
    restoreApproved: async (id) => {
      await db
        .update(vaultCliAuthRequests)
        .set({ status: "approved" })
        .where(and(eq(vaultCliAuthRequests.id, id), eq(vaultCliAuthRequests.status, "claimed")));
    },
  };
}
