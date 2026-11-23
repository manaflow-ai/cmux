import { and, desc, eq, gt, lte, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudIntroPasses as passes } from "../../db/schema";
import { CLOUD_ENTRY_OFFER_LOCK_KEY } from "./cloudIntroPasses";
import {
  CLOUD_INTRO_STATEMENT_DAYS,
  CLOUD_INTRO_STATEMENT_LATE_MS,
  cloudIntroStatementLog,
  dueCloudIntroStatement,
  type CloudIntroStatement,
  type CloudIntroStatementDay,
  type CloudIntroStatementDelivery,
  type CloudIntroStatementDue,
  type CloudIntroStatementLog,
  type CloudIntroStatementPass,
  type CloudIntroStatementRecord,
  type CloudIntroRenewalStatus,
} from "./cloudIntroStatements";

const DAY_MS = 24 * 60 * 60 * 1000;

/** A pass row as the statement step sees it. */
export type CloudIntroStatementRow = CloudIntroStatementPass & {
  readonly stripeCustomerId: string | null;
  readonly paymentMethodId: string | null;
  readonly renewalStatus?: CloudIntroRenewalStatus | null;
};

export type CloudIntroStatementClaim = {
  readonly pass: CloudIntroStatementRow;
  readonly day: CloudIntroStatementDay;
  readonly statement: CloudIntroStatement;
};

/**
 * Storage for the pass statements, on `cloud_intro_passes.statements`.
 *
 * `claim` is the at-most-once step: under the entry-offer lock and the row
 * lock it re-reads the row, decides what is due on that fresh row, builds the
 * statement and records it as `pending` before anything is sent. A second
 * cron run, or one racing the first, finds the day recorded and claims
 * nothing. An email that fails after the claim is recorded as
 * `email_failed` and is not sent again; the dashboard still shows it.
 */
export type CloudIntroStatementStore = {
  /** Granted passes that may have a statement due at `now`. */
  listCandidates(now: Date): Promise<readonly CloudIntroStatementRow[]>;
  claim(
    checkoutSessionId: string,
    now: Date,
    /** Null holds the statement: nothing is recorded and a later run decides again. */
    build: (pass: CloudIntroStatementRow, due: CloudIntroStatementDue) => CloudIntroStatement | null,
  ): Promise<CloudIntroStatementClaim | null>;
  markDelivery(checkoutSessionId: string, day: CloudIntroStatementDay, delivery: CloudIntroStatementDelivery): Promise<void>;
  /** The buyer's most recent granted pass, for the dashboard notice. */
  latestForUser(stackUserId: string): Promise<CloudIntroStatementRow | null>;
};

/** The log after a claim: the superseded days and the claimed day, `pending`. */
export function claimedStatementLog(
  log: CloudIntroStatementLog,
  due: CloudIntroStatementDue,
  statement: CloudIntroStatement,
  now: Date,
): CloudIntroStatementLog {
  const at = now.toISOString();
  const next: Partial<Record<`${CloudIntroStatementDay}`, CloudIntroStatementRecord>> = { ...log };
  for (const day of due.superseded) next[`${day}`] = { at, delivery: "superseded" };
  next[`${due.day}`] = { at, delivery: "pending", statement };
  return next;
}

export function statementRowFromPass(row: typeof passes.$inferSelect): CloudIntroStatementRow {
  return {
    checkoutSessionId: row.checkoutSessionId,
    stackUserId: row.stackUserId,
    status: row.status,
    renewOnPlus: row.renewOnPlus,
    startedAt: row.startedAt,
    endsAt: row.endsAt,
    statements: cloudIntroStatementLog(row.statements),
    stripeCustomerId: row.stripeCustomerId,
    paymentMethodId: row.paymentMethodId,
    renewalStatus: (row.renewalStatus as CloudIntroRenewalStatus | null) ?? null,
  };
}

export function createDrizzleCloudIntroStatementStore(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): CloudIntroStatementStore {
  const firstDay = CLOUD_INTRO_STATEMENT_DAYS[0];
  return {
    async listCandidates(now) {
      const rows = await db()
        .select()
        .from(passes)
        .where(and(
          eq(passes.status, "granted"),
          lte(passes.startedAt, new Date(now.getTime() - (firstDay - 1) * DAY_MS)),
          gt(passes.endsAt, new Date(now.getTime() - CLOUD_INTRO_STATEMENT_LATE_MS)),
        ))
        .limit(500);
      return rows.map(statementRowFromPass);
    },

    async claim(checkoutSessionId, now, build) {
      return await db().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${CLOUD_ENTRY_OFFER_LOCK_KEY}, 0))`);
        const [row] = await tx
          .select()
          .from(passes)
          .where(eq(passes.checkoutSessionId, checkoutSessionId))
          .for("update");
        if (!row) return null;
        const pass = statementRowFromPass(row);
        const due = dueCloudIntroStatement(pass, now);
        if (!due) return null;
        const statement = build(pass, due);
        if (!statement) return null;
        await tx
          .update(passes)
          .set({
            statements: claimedStatementLog(pass.statements, due, statement, now) as Record<string, unknown>,
            updatedAt: sql`now()`,
          })
          .where(eq(passes.checkoutSessionId, checkoutSessionId));
        return { pass, day: due.day, statement };
      });
    },

    async markDelivery(checkoutSessionId, day, delivery) {
      await db()
        .update(passes)
        .set({
          statements: sql`jsonb_set(${passes.statements}, ${`{${day},delivery}`}::text[], to_jsonb(${delivery}::text))`,
          updatedAt: sql`now()`,
        })
        .where(and(
          eq(passes.checkoutSessionId, checkoutSessionId),
          sql`(${passes.statements} -> ${`${day}`}::text) is not null`,
        ));
    },

    async latestForUser(stackUserId) {
      const [row] = await db()
        .select()
        .from(passes)
        .where(and(eq(passes.stackUserId, stackUserId), eq(passes.status, "granted")))
        .orderBy(desc(passes.startedAt))
        .limit(1);
      return row ? statementRowFromPass(row) : null;
    },
  };
}
