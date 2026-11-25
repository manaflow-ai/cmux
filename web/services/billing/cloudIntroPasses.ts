import { and, arrayOverlaps, count, eq, gte, inArray, isNotNull, ne, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { appleSubscriptions, cloudIntroPasses, stripeSubscriptions } from "../../db/schema";
import { cloudIntroUtcDayStart, type CloudIntroFacts, type CloudIntroRefusal } from "./cloudIntro";
import { ACTIVE_STRIPE_PRO_STATUSES, TEAM_PLAN_ID, isPaidPlanId } from "./pro";

/**
 * Storage for the $1 pass: rows of `cloud_intro_passes`, one per pass checkout.
 *
 * - A started checkout is recorded `open` and counts as a card attempt.
 * - `settle` decides an `open` row once, under one advisory lock for every
 *   pass, so the once-per-account, once-per-card, once-per-team rules and the
 *   caps hold against concurrent payments. A settled row is returned as is,
 *   which makes a redelivered event or a second event of one payment a no-op.
 * - The partial unique indexes on granted rows (account, card fingerprint) and
 *   on the PaymentIntent back the lock.
 */
export type CloudIntroPassStatus = "open" | "granted" | "refused";

export type CloudIntroPass = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
  readonly status: CloudIntroPassStatus;
  readonly refusal: CloudIntroRefusal | null;
  readonly paymentIntentId: string | null;
  readonly refundId: string | null;
  readonly renewOnPlus: boolean;
  readonly startedAt: Date | null;
  readonly endsAt: Date | null;
};

/** The facts the store owns; the account's plan history comes from elsewhere. */
export type CloudIntroStoreFacts = Pick<
  CloudIntroFacts,
  "hadPass" | "teamHadPass" | "grantedToday" | "grantedTotal" | "cardAttempts" | "cardFingerprintUsed"
>;

export type CloudIntroCheckoutRecord = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
  readonly stackTeamIds: readonly string[];
  readonly renewOnPlus: boolean;
};

export type CloudIntroSettlement = CloudIntroCheckoutRecord & {
  readonly paymentIntentId: string;
  readonly stripeCustomerId: string | null;
  readonly cardFingerprint: string | null;
  readonly cardFunding: string | null;
  /** The saved card, only when the buyer chose to continue on Plus. */
  readonly paymentMethodId: string | null;
  readonly startedAt: Date;
  readonly endsAt: Date;
};

export type CloudIntroPassStore = {
  /** Facts for the checkout stage, before any card is known. */
  checkoutFacts(input: {
    readonly stackUserId: string;
    readonly stackTeamIds: readonly string[];
    readonly now: Date;
  }): Promise<CloudIntroStoreFacts>;
  /** Record a started checkout as `open`. */
  recordCheckout(record: CloudIntroCheckoutRecord): Promise<void>;
  /**
   * Decide an `open` row (inserting it when the checkout's own insert was
   * lost): `judge` sees the facts with this row excluded, and its refusal, or
   * null for a grant, is stored. A row already settled is returned unchanged.
   */
  settle(
    input: CloudIntroSettlement,
    judge: (facts: CloudIntroStoreFacts) => CloudIntroRefusal | null,
  ): Promise<CloudIntroPass>;
  /** Record the refund of a refused pass's payment. */
  markRefunded(checkoutSessionId: string, refundId: string): Promise<void>;
};

const passes = cloudIntroPasses;
const SETTLE_LOCK_KEY = "cmux:cloud_intro:settle";

export function createDrizzleCloudIntroPassStore(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): CloudIntroPassStore {
  return {
    async checkoutFacts({ stackUserId, stackTeamIds, now }) {
      return await storeFacts(db(), { stackUserId, stackTeamIds, now, excludeSessionId: null, cardFingerprint: null });
    },

    async recordCheckout(record) {
      await db()
        .insert(passes)
        .values({
          checkoutSessionId: record.checkoutSessionId,
          stackUserId: record.stackUserId,
          stackTeamIds: [...record.stackTeamIds],
          renewOnPlus: record.renewOnPlus,
        })
        .onConflictDoNothing({ target: passes.checkoutSessionId });
    },

    async settle(input, judge) {
      return await db().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${SETTLE_LOCK_KEY}, 0))`);
        await tx
          .insert(passes)
          .values({
            checkoutSessionId: input.checkoutSessionId,
            stackUserId: input.stackUserId,
            stackTeamIds: [...input.stackTeamIds],
            renewOnPlus: input.renewOnPlus,
          })
          .onConflictDoNothing({ target: passes.checkoutSessionId });
        const [row] = await tx
          .select()
          .from(passes)
          .where(eq(passes.checkoutSessionId, input.checkoutSessionId))
          .for("update");
        if (!row) throw new Error("cmux Cloud pass row is missing after insert");
        if (row.status !== "open") return passFromRow(row);
        const facts = await storeFacts(tx as unknown as ReturnType<typeof cloudDb>, {
          stackUserId: input.stackUserId,
          stackTeamIds: input.stackTeamIds,
          now: input.startedAt,
          excludeSessionId: input.checkoutSessionId,
          cardFingerprint: input.cardFingerprint,
        });
        const refusal = judge(facts);
        const [settled] = await tx
          .update(passes)
          .set({
            status: refusal ? "refused" : "granted",
            refusal,
            paymentIntentId: input.paymentIntentId,
            stripeCustomerId: input.stripeCustomerId,
            cardFingerprint: input.cardFingerprint,
            cardFunding: input.cardFunding,
            paymentMethodId: refusal ? null : input.paymentMethodId,
            startedAt: refusal ? null : input.startedAt,
            endsAt: refusal ? null : input.endsAt,
            updatedAt: sql`now()`,
          })
          .where(eq(passes.checkoutSessionId, input.checkoutSessionId))
          .returning();
        if (!settled) throw new Error("cmux Cloud pass row disappeared while settling");
        return passFromRow(settled);
      });
    },

    async markRefunded(checkoutSessionId, refundId) {
      await db()
        .update(passes)
        .set({ refundId, updatedAt: sql`now()` })
        .where(eq(passes.checkoutSessionId, checkoutSessionId));
    },
  };
}

async function storeFacts(
  db: ReturnType<typeof cloudDb>,
  input: {
    readonly stackUserId: string;
    readonly stackTeamIds: readonly string[];
    readonly now: Date;
    readonly excludeSessionId: string | null;
    readonly cardFingerprint: string | null;
  },
): Promise<CloudIntroStoreFacts> {
  const others = input.excludeSessionId ? ne(passes.checkoutSessionId, input.excludeSessionId) : undefined;
  const granted = eq(passes.status, "granted");
  const [userRows, teamRows, cardRows, todayRows, totalRows, attemptRows] = await Promise.all([
    db.select({ n: count() }).from(passes).where(and(granted, eq(passes.stackUserId, input.stackUserId), others)),
    input.stackTeamIds.length === 0
      ? Promise.resolve([{ n: 0 }])
      : db.select({ n: count() }).from(passes).where(and(
          granted,
          arrayOverlaps(passes.stackTeamIds, [...input.stackTeamIds]),
          ne(passes.stackUserId, input.stackUserId),
          others,
        )),
    input.cardFingerprint
      ? db.select({ n: count() }).from(passes).where(and(granted, eq(passes.cardFingerprint, input.cardFingerprint), others))
      : Promise.resolve([{ n: 0 }]),
    db.select({ n: count() }).from(passes).where(and(granted, gte(passes.startedAt, cloudIntroUtcDayStart(input.now)), others)),
    db.select({ n: count() }).from(passes).where(and(granted, others)),
    db.select({ n: count() }).from(passes).where(and(eq(passes.stackUserId, input.stackUserId), others)),
  ]);
  return {
    hadPass: (userRows[0]?.n ?? 0) > 0,
    teamHadPass: (teamRows[0]?.n ?? 0) > 0,
    cardFingerprintUsed: (cardRows[0]?.n ?? 0) > 0,
    grantedToday: todayRows[0]?.n ?? 0,
    grantedTotal: totalRows[0]?.n ?? 0,
    cardAttempts: attemptRows[0]?.n ?? 0,
  };
}

function passFromRow(row: typeof cloudIntroPasses.$inferSelect): CloudIntroPass {
  return {
    checkoutSessionId: row.checkoutSessionId,
    stackUserId: row.stackUserId,
    status: row.status,
    refusal: (row.refusal as CloudIntroRefusal | null) ?? null,
    paymentIntentId: row.paymentIntentId,
    refundId: row.refundId,
    renewOnPlus: row.renewOnPlus,
    startedAt: row.startedAt,
    endsAt: row.endsAt,
  };
}

/** The account facts the store does not own: plan history and Team seats. */
export type CloudIntroAccountFacts = Pick<CloudIntroFacts, "hadPaidPlan" | "isTeamSeat"> & {
  readonly stackTeamIds: readonly string[];
};

export type CloudIntroAccountUser = {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
  listTeams?(): Promise<readonly { readonly id?: string }[]>;
};

export type CloudIntroAccountFactsQuery = (user: CloudIntroAccountUser) => Promise<CloudIntroAccountFacts>;

/**
 * Whether the account ever had a paid plan (any Stripe subscription row it
 * owns or bought, Founder's Edition included; any App Store subscription; a
 * paid `cmuxPlan` or `cmuxVmPlan`), and whether it holds a seat on a team
 * with an active Team plan.
 */
export function createDrizzleCloudIntroAccountFacts(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): CloudIntroAccountFactsQuery {
  return async (user) => {
    const teams = user.listTeams ? await user.listTeams() : [];
    const stackTeamIds = teams
      .map((team) => team.id)
      .filter((id): id is string => typeof id === "string" && id.length > 0);
    const metadata = user.clientReadOnlyMetadata && typeof user.clientReadOnlyMetadata === "object"
      ? user.clientReadOnlyMetadata as Record<string, unknown>
      : {};
    const metadataPaid = [metadata.cmuxPlan, metadata.cmuxVmPlan]
      .some((value) => typeof value === "string" && isPaidPlanId(value.trim().toLowerCase()));
    const [stripeRows, appleRows, seatRows] = await Promise.all([
      db().select({ id: stripeSubscriptions.id }).from(stripeSubscriptions)
        .where(eq(stripeSubscriptions.stackUserId, user.id)).limit(1),
      db().select({ id: appleSubscriptions.originalTransactionId }).from(appleSubscriptions)
        .where(eq(appleSubscriptions.userId, user.id)).limit(1),
      stackTeamIds.length === 0
        ? Promise.resolve([])
        : db().select({ id: stripeSubscriptions.id }).from(stripeSubscriptions)
          .where(and(
            isNotNull(stripeSubscriptions.stackTeamId),
            inArray(stripeSubscriptions.stackTeamId, stackTeamIds),
            or(eq(stripeSubscriptions.scope, "team"), eq(stripeSubscriptions.plan, TEAM_PLAN_ID)),
            inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
          ))
          .limit(1),
    ]);
    return {
      hadPaidPlan: metadataPaid || stripeRows.length > 0 || appleRows.length > 0,
      isTeamSeat: seatRows.length > 0,
      stackTeamIds,
    };
  };
}
