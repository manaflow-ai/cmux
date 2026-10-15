// Admin revocation of Founder's Edition access.
//
// Founder's Edition is a one-time purchase recorded as a durable active
// personal "pro" row in stripe_subscriptions (see `isFounderSubscriptionRow`).
// Provider lifecycle events never clear it, so an operator decision is the
// only way to remove that access. Revoking sets the row to "canceled" and
// writes a durable marker at `raw.cmux_admin_revocation`. Every writer that
// could re-record the purchase (checkout webhook, success callback, recovery,
// paid-purchase and lockout backfills) refuses to touch a row that carries
// the marker, so a replay cannot bring the access back. The marker is kept
// outside `raw.metadata` so it never mixes with Stripe-shaped metadata that
// other code copies back to the provider.

import { and, eq, inArray, isNull, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { accountDeletionAdvisoryLockKey } from "../account/deletionLock";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PERSONAL_PLAN_IDS,
  isFounderSubscriptionRow,
} from "./pro";

export const FOUNDER_ADMIN_REVOCATION_KEY = "cmux_admin_revocation";
/** Status written to a revoked Founder row; not in ACTIVE_STRIPE_PRO_STATUSES. */
export const FOUNDER_REVOKED_STATUS = "canceled";

export type FounderAdminRevocation = {
  readonly byUserId: string;
  readonly byEmail: string | null;
  /** ISO timestamp. */
  readonly at: string;
  /** The row status before the revocation, kept for audit. */
  readonly previousStatus?: string | null;
};

/** The revocation marker on a subscription row's raw JSON, or null. */
export function founderAdminRevocationFromRaw(raw: unknown): FounderAdminRevocation | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const marker = (raw as Record<string, unknown>)[FOUNDER_ADMIN_REVOCATION_KEY];
  if (!marker || typeof marker !== "object" || Array.isArray(marker)) return null;
  const value = marker as Record<string, unknown>;
  if (typeof value.byUserId !== "string" || typeof value.at !== "string") return null;
  return {
    byUserId: value.byUserId,
    byEmail: typeof value.byEmail === "string" ? value.byEmail : null,
    at: value.at,
    previousStatus: typeof value.previousStatus === "string" ? value.previousStatus : null,
  };
}

/** True when an admin revoked the purchase behind this subscription row. */
export function isAdminRevokedSubscriptionRaw(raw: unknown): boolean {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  return (raw as Record<string, unknown>)[FOUNDER_ADMIN_REVOCATION_KEY] != null;
}

/**
 * SQL predicate: the row carries no admin revocation marker. A JSON null
 * marker counts as absent, matching `isAdminRevokedSubscriptionRaw`.
 */
export function notAdminRevokedSql() {
  return sql`coalesce(jsonb_typeof(${stripeSubscriptions.raw} -> ${FOUNDER_ADMIN_REVOCATION_KEY}), 'null') = 'null'`;
}

/**
 * Whether any stored row among these ids carries the revocation marker. One
 * Founder purchase can be keyed under several ids (provider subscription,
 * payment_intent, or the synthetic founders_<session> id), so recorders pass
 * every candidate. Every Founder recorder checks this under the account
 * advisory lock, so a webhook, success-callback, recovery, or backfill
 * replay of a revoked purchase is a no-op.
 */
export async function isAdminRevokedPurchase(
  db: Pick<ReturnType<typeof cloudDb>, "select">,
  rowIds: readonly string[],
): Promise<boolean> {
  if (rowIds.length === 0) return false;
  const rows = await db
    .select({
      id: stripeSubscriptions.id,
      adminRevocation: sql<unknown>`${stripeSubscriptions.raw} -> ${FOUNDER_ADMIN_REVOCATION_KEY}`,
    })
    .from(stripeSubscriptions)
    .where(inArray(stripeSubscriptions.id, [...rowIds]))
    .limit(rowIds.length);
  return rows.some((row) => row.adminRevocation != null);
}

export type FounderPurchaseRow = {
  readonly id: string;
  readonly status: string;
  readonly raw: unknown;
};

export type FounderPurchaseStore = {
  /** Ids of the user's Founder rows that currently grant access. */
  activeFounderPurchaseIds(stackUserId: string): Promise<string[]>;
  /**
   * Cancels every active Founder row for the user and writes the revocation
   * marker. Recurring subscriptions are never selected. Returns the revoked
   * row ids; an empty list means there was nothing to revoke.
   */
  revokeActiveFounderPurchases(
    stackUserId: string,
    revocation: Omit<FounderAdminRevocation, "previousStatus">,
  ): Promise<string[]>;
};

type FounderStoreDb = Pick<ReturnType<typeof cloudDb>, "select" | "update" | "transaction">;

/** Active, unrevoked Founder rows among a user's personal subscription rows. */
export function activeFounderRows<Row extends FounderPurchaseRow>(rows: readonly Row[]): Row[] {
  return rows.filter((row) =>
    isFounderSubscriptionRow(row) &&
    !isAdminRevokedSubscriptionRaw(row.raw) &&
    (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(row.status)
  );
}

/** The raw JSON written to a revoked Founder row. */
export function revokedFounderRaw(
  raw: unknown,
  revocation: Omit<FounderAdminRevocation, "previousStatus">,
  previousStatus: string,
): Record<string, unknown> {
  const base = raw && typeof raw === "object" && !Array.isArray(raw)
    ? { ...(raw as Record<string, unknown>) }
    : {};
  const marker: FounderAdminRevocation = {
    byUserId: revocation.byUserId,
    byEmail: revocation.byEmail,
    at: revocation.at,
    previousStatus,
  };
  return { ...base, [FOUNDER_ADMIN_REVOCATION_KEY]: marker };
}

/** SQL predicate matching `isFounderSubscriptionRow`: synthetic id or the Founder marker. */
function founderRowSql() {
  return sql`(left(${stripeSubscriptions.id}, 9) = 'founders_' or coalesce(${stripeSubscriptions.raw}->'metadata'->>'founders_edition', '') = 'true')`;
}

// Every active Founder row for the user, selected in SQL and uncapped, so an
// old purchase behind many newer personal rows is never missed.
function personalRowsQuery(db: Pick<FounderStoreDb, "select">, stackUserId: string) {
  return db
    .select({
      id: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        isNull(stripeSubscriptions.stackTeamId),
        eq(stripeSubscriptions.scope, "user"),
        inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        founderRowSql(),
        notAdminRevokedSql(),
      ),
    );
}

export function makeFounderPurchaseStore(injected?: FounderStoreDb): FounderPurchaseStore {
  // Resolved per call so a read-only caller without database configuration
  // degrades to "no Founder purchase" instead of throwing at construction.
  const database = () => injected ?? cloudDb();
  return {
    async activeFounderPurchaseIds(stackUserId) {
      try {
        return activeFounderRows(await personalRowsQuery(database(), stackUserId)).map((row) => row.id);
      } catch (error) {
        if (isMissingDatabaseConfig(error)) return [];
        throw error;
      }
    },
    async revokeActiveFounderPurchases(stackUserId, revocation) {
      // Same advisory lock as the checkout recorders, so a concurrent
      // webhook either commits before this read (and is revoked here) or
      // runs after it and sees the marker.
      return await database().transaction(async (tx) => {
        await tx.execute(
          sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(stackUserId)}, 0))`,
        );
        const rows = activeFounderRows(await personalRowsQuery(tx, stackUserId));
        for (const row of rows) {
          await tx
            .update(stripeSubscriptions)
            .set({
              status: FOUNDER_REVOKED_STATUS,
              cancelAtPeriodEnd: false,
              raw: revokedFounderRaw(row.raw, revocation, row.status),
              updatedAt: sql`now()`,
            })
            .where(
              and(
                eq(stripeSubscriptions.id, row.id),
                eq(stripeSubscriptions.stackUserId, stackUserId),
                eq(stripeSubscriptions.scope, "user"),
                isNull(stripeSubscriptions.stackTeamId),
              ),
            );
        }
        return rows.map((row) => row.id);
      });
    },
  };
}

function isMissingDatabaseConfig(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}
