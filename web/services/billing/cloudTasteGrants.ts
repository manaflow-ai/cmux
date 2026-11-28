import { sql, type SQL } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { getStackServerApp } from "../../app/lib/stack";
import { withFreshAccountMetadataUser } from "../account/metadataMutation";
import type { AccountDeletionUserMutationLease } from "../account/deletionLock";
import {
  CLOUD_INTRO_METADATA_KEYS,
  CLOUD_INTRO_PLAN_ID,
  CLOUD_TASTE_PLAN_ID,
  cloudIntroUtcDayStart,
  withCloudEntryGrant,
  type CloudIntroTerm,
} from "./cloudIntro";
import {
  CLOUD_ENTRY_OFFER_LOCK_KEY,
  createDrizzleCloudIntroAccountFacts,
  type CloudIntroAccountFactsQuery,
  type CloudIntroAccountUser,
} from "./cloudIntroPasses";
import { cloudTasteRefusal, cloudTasteTerm, type CloudTasteFacts, type CloudTasteRefusal } from "./cloudTaste";

/**
 * Storage and grant of the free week: one row of `cloud_taste_grants` per
 * person ever granted one. `grant` decides under the same advisory lock the
 * pass's settle takes, reading "had a pass", "had a free week", the team rule
 * and today's count in one query, so the once-per-person, once-per-team and
 * daily-cap rules hold against concurrent grants and payments.
 */
export type CloudTasteGrant = {
  readonly stackUserId: string;
  readonly startedAt: Date;
  readonly endsAt: Date;
};

export type CloudTasteStoreFacts = Pick<CloudTasteFacts, "hadPass" | "hadTaste" | "teamHadTaste" | "grantedToday">;

export type CloudTasteGrantInput = {
  readonly stackUserId: string;
  readonly stackTeamIds: readonly string[];
  readonly now: Date;
};

export type CloudTasteDecision =
  /** `existing`: the person's own earlier grant, answered again with no new row. */
  | { readonly status: "granted"; readonly grant: CloudTasteGrant; readonly existing: boolean }
  | { readonly status: "refused"; readonly refusal: CloudTasteRefusal };

export type CloudTasteStore = {
  /**
   * The person's existing grant, or `judge`'s decision over the store's facts:
   * a refusal stores nothing; null inserts the grant for `now` to `now + 7 days`.
   */
  grant(
    input: CloudTasteGrantInput,
    judge: (facts: CloudTasteStoreFacts) => CloudTasteRefusal | null,
  ): Promise<{ readonly existing: CloudTasteGrant | null; readonly decision: CloudTasteDecision }>;
};

type FactsRow = {
  own_started_at: string | Date | null;
  own_ends_at: string | Date | null;
  had_pass: boolean;
  team_had_taste: boolean;
  granted_today: number | string;
};

/** A text[] literal; an array parameter would expand into a list. */
function textArray(values: readonly string[]): SQL {
  if (values.length === 0) return sql`'{}'::text[]`;
  return sql`array[${sql.join(values.map((value) => sql`${value}`), sql`, `)}]::text[]`;
}

function teamOverlap(stackUserId: string, stackTeamIds: readonly string[]): SQL {
  if (stackTeamIds.length === 0) return sql`false`;
  return sql`exists (
    select 1 from cloud_taste_grants
    where stack_team_ids && ${textArray(stackTeamIds)} and stack_user_id <> ${stackUserId}
  )`;
}

export function createDrizzleCloudTasteStore(db: () => ReturnType<typeof cloudDb> = cloudDb): CloudTasteStore {
  return {
    async grant(input, judge) {
      return await db().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${CLOUD_ENTRY_OFFER_LOCK_KEY}, 0))`);
        const dayStart = cloudIntroUtcDayStart(input.now).toISOString();
        const rows = await tx.execute(sql`
          select
            own.started_at as own_started_at,
            own.ends_at as own_ends_at,
            exists (
              select 1 from cloud_intro_passes
              where stack_user_id = ${input.stackUserId} and status = 'granted'
            ) as had_pass,
            ${teamOverlap(input.stackUserId, input.stackTeamIds)} as team_had_taste,
            (select count(*)::int from cloud_taste_grants where started_at >= ${dayStart}::timestamptz) as granted_today
          from (select 1) as one
          left join cloud_taste_grants own on own.stack_user_id = ${input.stackUserId}
        `);
        const row = rows[0] as FactsRow | undefined;
        if (!row) throw new Error("cmux Cloud free week facts query returned no row");
        const existing = row.own_started_at && row.own_ends_at
          ? { stackUserId: input.stackUserId, startedAt: new Date(row.own_started_at), endsAt: new Date(row.own_ends_at) }
          : null;
        const decision = decide(existing, input, judge({
          hadPass: row.had_pass === true,
          hadTaste: existing !== null,
          teamHadTaste: row.team_had_taste === true,
          grantedToday: Number(row.granted_today) || 0,
        }));
        if (decision.status === "granted" && !decision.existing) {
          await tx.execute(sql`
            insert into cloud_taste_grants (stack_user_id, stack_team_ids, started_at, ends_at)
            values (
              ${input.stackUserId},
              ${textArray(input.stackTeamIds)},
              ${decision.grant.startedAt.toISOString()}::timestamptz,
              ${decision.grant.endsAt.toISOString()}::timestamptz
            )
          `);
        }
        return { existing, decision };
      });
    },
  };
}

/**
 * The decision the store records, shared with the in-memory store in tests:
 * the person's own grant, while it runs, is answered again before any rule;
 * otherwise `refusal` (the judge's answer, which refuses an ended week through
 * `hadTaste`) or a new 7-day grant from `now`.
 */
export function decide(
  existing: CloudTasteGrant | null,
  input: CloudTasteGrantInput,
  refusal: CloudTasteRefusal | null,
): CloudTasteDecision {
  if (existing && existing.endsAt.getTime() > input.now.getTime()) {
    return { status: "granted", grant: existing, existing: true };
  }
  if (refusal) return { status: "refused", refusal };
  const term = cloudTasteTerm(input.now);
  return {
    status: "granted",
    grant: { stackUserId: input.stackUserId, startedAt: term.startedAt, endsAt: term.endsAt },
    existing: false,
  };
}

export type CloudTasteDependencies = {
  readonly now?: () => Date;
  readonly store: CloudTasteStore;
  readonly accountFacts: CloudIntroAccountFactsQuery;
  /** Writes the free week into the account's metadata; false when nothing was written. */
  readonly writeGrant: (stackUserId: string, term: CloudIntroTerm) => Promise<boolean>;
};

let defaults: CloudTasteDependencies | null = null;

export function defaultCloudTasteDependencies(): CloudTasteDependencies {
  defaults ??= {
    store: createDrizzleCloudTasteStore(),
    accountFacts: createDrizzleCloudIntroAccountFacts(),
    writeGrant: writeCloudTasteGrant,
  };
  return defaults;
}

/**
 * Grant the free week to a signed-in person, or say why not. The flag is the
 * caller's to check. A repeat call while the week runs answers the same grant
 * and writes the metadata again only if it is missing.
 */
export async function grantCloudTaste(
  user: CloudIntroAccountUser,
  dependencies: CloudTasteDependencies,
): Promise<CloudTasteDecision> {
  const now = dependencies.now?.() ?? new Date();
  const account = await dependencies.accountFacts(user);
  const { decision } = await dependencies.store.grant(
    { stackUserId: user.id, stackTeamIds: account.stackTeamIds, now },
    (facts) => cloudTasteRefusal({ ...facts, hadPaidPlan: account.hadPaidPlan, isTeamSeat: account.isTeamSeat }),
  );
  if (decision.status === "granted" && decision.grant.endsAt.getTime() > now.getTime()) {
    await dependencies.writeGrant(user.id, { startedAt: decision.grant.startedAt, endsAt: decision.grant.endsAt });
  }
  return decision;
}

/**
 * The metadata with the free week written in, or null when nothing should be
 * written: it is already there, or a $1 pass holds the keys (a pass always
 * wins over the free week, whichever was written last).
 */
export function withCloudTasteGrant(raw: unknown, term: CloudIntroTerm): Record<string, unknown> | null {
  const metadata = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : {};
  if (metadata[CLOUD_INTRO_METADATA_KEYS.plan] === CLOUD_INTRO_PLAN_ID) return null;
  return withCloudEntryGrant(metadata, CLOUD_TASTE_PLAN_ID, term);
}

type GrantUser = CloudIntroAccountUser & {
  update(options: { clientReadOnlyMetadata: Record<string, unknown> }): Promise<unknown>;
};

/** Writes the free week under the account mutation lease, like the pass. */
async function writeCloudTasteGrant(stackUserId: string, term: CloudIntroTerm): Promise<boolean> {
  const app = getStackServerApp();
  return await withFreshAccountMetadataUser({
    db: cloudDb(),
    userId: stackUserId,
    loader: { getUser: async (id) => (await app.getUser(id)) as GrantUser | null },
    operation: async (user: GrantUser, lease: AccountDeletionUserMutationLease) => {
      const metadata = user.clientReadOnlyMetadata as Record<string, unknown> | undefined;
      if (metadata?.cmuxAccountDeleting === true) return false;
      const next = withCloudTasteGrant(metadata, term);
      if (!next) return false;
      await lease.refresh();
      await user.update({ clientReadOnlyMetadata: next });
      return true;
    },
  });
}
