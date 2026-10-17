// Postgres persistence for the iOS Pro trial: single-use challenges, App
// Attest keys and one trial claim per account (db/schema.ts).

import { and, eq, gt, isNull, lt, or, sql } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { appleAppAttestKeys, appleSubscriptions, appleTrialChallenges, appleTrialClaims } from "../../../db/schema";

type Db = ReturnType<typeof cloudDb>;

export type AttestKeyRow = {
  readonly keyId: string;
  readonly userId: string;
  readonly publicKeySpki: string;
  readonly signCount: number;
  readonly environment: string;
};

export type TrialClaimRow = {
  readonly userId: string;
  readonly keyId: string;
  readonly deviceCheckToken: string | null;
  /** `device_reused`: the trial started on an iPhone that already had one; it grants nothing. */
  readonly status: "verified" | "started" | "device_reused";
  readonly startedAt: Date | null;
  readonly originalTransactionId: string | null;
  readonly deviceMarkAttemptedAt: Date | null;
  readonly deviceMarkedAt: Date | null;
  /** The trial's entitlement was applied and `trial_started` sent. */
  readonly grantedAt: Date | null;
};

export type TrialStore = {
  readonly issueChallenge: (userId: string, challenge: string, expiresAt: Date, now: Date) => Promise<void>;
  /** Deletes and returns true only for an unexpired challenge issued to this user. */
  readonly consumeChallenge: (userId: string, challenge: string, now: Date) => Promise<boolean>;
  readonly attestKey: (keyId: string) => Promise<AttestKeyRow | null>;
  /** Binds a newly attested key to the user; returns the owner (an existing owner wins). */
  readonly bindAttestKey: (key: Omit<AttestKeyRow, "signCount">) => Promise<string>;
  /** Moves the sign count forward; false when another request already used a count this high. */
  readonly advanceSignCount: (keyId: string, signCount: number) => Promise<boolean>;
  readonly claim: (userId: string) => Promise<TrialClaimRow | null>;
  /** Records a verified claim unless the account already started a trial. */
  readonly recordVerifiedClaim: (userId: string, keyId: string, deviceCheckToken: string) => Promise<boolean>;
  /** Recorded before bit0 is written, so a retry can tell its own mark from another account's. */
  readonly markDeviceMarkAttempted: (userId: string, now: Date) => Promise<void>;
  readonly markDeviceMarked: (userId: string, now: Date) => Promise<void>;
  /** Only a claim that never tried to mark its device can be a reused device. */
  readonly markDeviceReused: (userId: string) => Promise<void>;
  readonly markGranted: (userId: string, now: Date) => Promise<void>;
  /** Runs `task` while holding this user's trial-settle lock (a transaction-scoped advisory lock). */
  readonly withTrialSettleLock: <T>(userId: string, task: () => Promise<T>) => Promise<T>;
  /** Moves a `trial_pending` subscription to its settled plan; no-op once settled. */
  readonly settleSubscriptionPlan: (originalTransactionId: string, planId: "go" | "trial_unverified") => Promise<boolean>;
  /** Active free-trial subscriptions still waiting for the device check, or granted but not finished. */
  readonly pendingTrialSubscriptions: (limit: number) => Promise<readonly (typeof appleSubscriptions.$inferSelect)[]>;
};

const claimColumns = {
  userId: appleTrialClaims.userId,
  keyId: appleTrialClaims.keyId,
  deviceCheckToken: appleTrialClaims.deviceCheckToken,
  status: appleTrialClaims.status,
  startedAt: appleTrialClaims.startedAt,
  originalTransactionId: appleTrialClaims.originalTransactionId,
  deviceMarkAttemptedAt: appleTrialClaims.deviceMarkAttemptedAt,
  deviceMarkedAt: appleTrialClaims.deviceMarkedAt,
  grantedAt: appleTrialClaims.grantedAt,
};

export function databaseTrialStore(db: () => Db = cloudDb): TrialStore {
  return {
    issueChallenge: async (userId, challenge, expiresAt, now) => {
      // One live challenge per user, and expired rows of every user are purged,
      // so the table stays bounded by the number of users verifying right now.
      await db().delete(appleTrialChallenges)
        .where(or(eq(appleTrialChallenges.userId, userId), lt(appleTrialChallenges.expiresAt, now)));
      await db().insert(appleTrialChallenges).values({ challenge, userId, expiresAt });
    },
    consumeChallenge: async (userId, challenge, now) => {
      const deleted = await db().delete(appleTrialChallenges)
        .where(and(
          eq(appleTrialChallenges.challenge, challenge),
          eq(appleTrialChallenges.userId, userId),
          gt(appleTrialChallenges.expiresAt, now),
        ))
        .returning({ challenge: appleTrialChallenges.challenge });
      return deleted.length === 1;
    },
    attestKey: async (keyId) => {
      const [row] = await db().select({
        keyId: appleAppAttestKeys.keyId,
        userId: appleAppAttestKeys.userId,
        publicKeySpki: appleAppAttestKeys.publicKeySpki,
        signCount: appleAppAttestKeys.signCount,
        environment: appleAppAttestKeys.environment,
      }).from(appleAppAttestKeys).where(eq(appleAppAttestKeys.keyId, keyId)).limit(1);
      return row ?? null;
    },
    bindAttestKey: async (key) => {
      await db().insert(appleAppAttestKeys).values({ ...key, signCount: 0 })
        .onConflictDoNothing({ target: appleAppAttestKeys.keyId });
      const [row] = await db().select({ userId: appleAppAttestKeys.userId })
        .from(appleAppAttestKeys).where(eq(appleAppAttestKeys.keyId, key.keyId)).limit(1);
      if (!row) throw new Error("App Attest key was not persisted");
      return row.userId;
    },
    advanceSignCount: async (keyId, signCount) => {
      const updated = await db().update(appleAppAttestKeys)
        .set({ signCount, updatedAt: sql`now()` })
        .where(and(eq(appleAppAttestKeys.keyId, keyId), lt(appleAppAttestKeys.signCount, signCount)))
        .returning({ keyId: appleAppAttestKeys.keyId });
      return updated.length === 1;
    },
    claim: async (userId) => {
      const [row] = await db().select(claimColumns).from(appleTrialClaims).where(eq(appleTrialClaims.userId, userId)).limit(1);
      return row ? { ...row, status: row.status as TrialClaimRow["status"] } : null;
    },
    recordVerifiedClaim: async (userId, keyId, deviceCheckToken) => {
      const rows = await db().insert(appleTrialClaims)
        .values({ userId, keyId, deviceCheckToken, status: "verified" })
        .onConflictDoUpdate({
          target: appleTrialClaims.userId,
          set: { keyId, deviceCheckToken, verifiedAt: sql`now()` },
          setWhere: eq(appleTrialClaims.status, "verified"),
        })
        .returning({ userId: appleTrialClaims.userId });
      return rows.length === 1;
    },
    markDeviceMarkAttempted: async (userId, now) => {
      await db().update(appleTrialClaims).set({ deviceMarkAttemptedAt: now }).where(eq(appleTrialClaims.userId, userId));
    },
    markDeviceMarked: async (userId, now) => {
      await db().update(appleTrialClaims).set({ deviceMarkedAt: now }).where(eq(appleTrialClaims.userId, userId));
    },
    markDeviceReused: async (userId) => {
      await db().update(appleTrialClaims).set({ status: "device_reused" })
        .where(and(
          eq(appleTrialClaims.userId, userId),
          eq(appleTrialClaims.status, "started"),
          isNull(appleTrialClaims.deviceMarkAttemptedAt),
          isNull(appleTrialClaims.deviceMarkedAt),
        ));
    },
    markGranted: async (userId, now) => {
      await db().update(appleTrialClaims).set({ grantedAt: now }).where(eq(appleTrialClaims.userId, userId));
    },
    withTrialSettleLock: async (userId, task) => await db().transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`apple-trial-settle:${userId}`}, 0))`);
      return await task();
    }),
    settleSubscriptionPlan: async (originalTransactionId, planId) => {
      const rows = await db().update(appleSubscriptions).set({ planId })
        .where(and(eq(appleSubscriptions.originalTransactionId, originalTransactionId), eq(appleSubscriptions.planId, "trial_pending")))
        .returning({ originalTransactionId: appleSubscriptions.originalTransactionId });
      return rows.length === 1;
    },
    pendingTrialSubscriptions: async (limit) => await db().select().from(appleSubscriptions)
      .where(and(
        eq(appleSubscriptions.freeTrial, true),
        eq(appleSubscriptions.status, "active"),
        or(
          eq(appleSubscriptions.planId, "trial_pending"),
          and(eq(appleSubscriptions.planId, "go"), sql`exists (
            select 1 from ${appleTrialClaims}
            where ${appleTrialClaims.userId} = ${appleSubscriptions.userId}
              and ${appleTrialClaims.originalTransactionId} = ${appleSubscriptions.originalTransactionId}
              and ${appleTrialClaims.deviceMarkedAt} is not null
              and ${appleTrialClaims.grantedAt} is null)`),
        ),
      ))
      .limit(limit),
  };
}
